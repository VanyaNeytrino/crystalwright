require "cdp"
require "./errors"
require "./lifecycle"
require "./frame"
require "./signal_barrier"
require "./input"
require "./route"
require "./progress"

module Crystalwright
  # The frame tree of one page, kept current from protocol events.
  #
  # Everything the page knows about *when* something is true lives here: which
  # frames exist, which document each is showing, how far into loading it has
  # got, whether its network has gone quiet, and whether an action just set off
  # a navigation that has not landed yet.
  #
  # Nothing polls. State changes arrive as events, are applied under one lock,
  # and then every waiter is woken to look again. The single exception is
  # `LoadState::NetworkIdle`, which becomes true through the passage of time
  # with no message to announce it, so a waiter for it says when to look again.
  class FrameManager
    Log = ::Log.for("crystalwright.route")

    # The protocol session for the page.
    getter session : CDP::Session

    # The name of this page's isolated world.
    getter utility_world_name : String

    # The mouse, in page coordinates.
    getter mouse : Mouse

    # The keyboard.
    getter keyboard : Keyboard

    # The shortest a waiter will sleep, so a recheck deadline of zero cannot
    # turn a wait into a spin.
    MINIMUM_SLICE = 1.millisecond

    @mutex = Sync::Mutex.new
    @frames = {} of String => Frame
    @waiters = [] of Channel(Nil)
    @barriers = [] of SignalBarrier
    # Request id to the frame that asked and the document it asked for. The
    # loader is here for the same reason it is in the accountant: a request the
    # old document abandoned is never mentioned again, so nothing else will
    # ever take this entry out.
    @request_frames = {} of String => Tuple(String, String)
    @routes = [] of RouteHandler
    @resync_on_commit = false
    @main_frame : Frame?

    # :nodoc:
    def initialize(@session : CDP::Session, @utility_world_name : String)
      @mouse = Mouse.new(@session)
      @keyboard = Keyboard.new(@session)
    end

    # The page's top frame.
    def main_frame : Frame
      @mutex.synchronize { @main_frame } ||
        raise Error.new("the frame tree has not been read yet")
    end

    # Every frame in the page, parents before children.
    def frames : Array(Frame)
      main_frame.subtree
    end

    # The frame with this `name` or `id` attribute, if it is still attached.
    def frame(name : String) : Frame?
      frames.find { |frame| frame.name == name }
    end

    # Runs an action that might navigate, and does not return until it has.
    #
    # The problem: a click returns as soon as the browser has been told about
    # it, which is long before any navigation it caused exists. The next call
    # then resolves a selector in a document that is about to be replaced and
    # fails in a way that looks random.
    #
    # The shape is Playwright's and so is the reasoning. Measured here, three
    # runs: `Page.frameRequestedNavigation` had always arrived by the time the
    # action returned, while `Page.frameStartedNavigating` arrived after it
    # twice and before it once — a barrier armed by the second would miss a
    # navigation one time in three.
    def with_signals(progress : Progress, &)
      barrier = SignalBarrier.new
      @mutex.synchronize { @barriers << barrier }
      begin
        result = yield
        input_action_epilogue
        settle(barrier, progress)
        result
      ensure
        @mutex.synchronize { @barriers.delete(barrier) }
      end
    end

    # Blocks until a condition holds, or the operation runs out of time.
    #
    # The predicate is called outside the lock and is free to take it. It is
    # also called *before* the first wait and the waiter is registered before
    # that, which together are what make this race-free: a change that lands
    # between the check and the wait has already left a token in the channel.
    #
    # `recheck` is for a condition that becomes true on its own, with no event
    # to announce it. It says how long until it is worth looking again.
    def wait_until(progress : Progress, what : String, recheck : Proc(Time::Span?)? = nil, &predicate : -> Bool) : Nil
      channel = Channel(Nil).new(1)
      @mutex.synchronize { @waiters << channel }

      begin
        loop do
          return if predicate.call
          raise progress.timed_out("waiting for #{what}") if progress.expired?
          progress.log("waiting for #{what}")

          slice = progress.remaining
          if recheck && (soon = recheck.call)
            slice = soon if soon < slice
          end
          slice = MINIMUM_SLICE if slice < MINIMUM_SLICE

          select
          when channel.receive
          when timeout(slice)
          end
        end
      ensure
        @mutex.synchronize { @waiters.delete(channel) }
      end
    end

    # :nodoc:
    #
    # Subscribes to everything first and enables afterwards, in that order.
    # `Runtime.enable` replays the contexts that already exist, so a
    # subscription installed after it misses the current document's worlds and
    # then waits for a navigation that may never come.
    protected def start(timeout : Time::Span) : Nil
      watch_page
      watch_runtime
      watch_network
      watch_fetch

      @session.execute(CDP::Protocol::Page::EnableRequest.new, timeout)
      @session.execute(CDP::Protocol::Page::SetLifecycleEventsEnabledRequest.new(enabled: true), timeout)

      # Registered before the tree is read, so that every frame appearing from
      # now on gets the isolated world with no further command. Measured: with
      # this in place a new iframe's utility world shows up alongside its main
      # world; without it the world exists for exactly one document.
      @session.execute(CDP::Protocol::Page::AddScriptToEvaluateOnNewDocumentRequest.new(
        source: "", world_name: @utility_world_name), timeout)

      # Before `Runtime.enable`, not after. Enabling replays every existing
      # context, and a context whose frame is unknown is dropped on the floor.
      tree = @session.execute(CDP::Protocol::Page::GetFrameTreeRequest.new, timeout)
      seed(tree.frame_tree)
      ring

      @session.execute(CDP::Protocol::Runtime::EnableRequest.new, timeout)
      @session.execute(CDP::Protocol::Network::EnableRequest.new, timeout)

      # Only the frames that already existed need to be told. Everything after
      # this point is covered by the empty script registered above.
      @mutex.synchronize { @frames.values.dup }.each do |frame|
        create_isolated_world(frame.id, timeout)
      end
    end

    private def seed(node : CDP::Protocol::Page::FrameTree) : Nil
      info = node.frame
      @mutex.synchronize do
        frame = upsert_locked(info.id, info.parent_id)
        frame.commit_locked(info.url, info.name || "", info.loader_id)
        @main_frame = frame if info.parent_id.nil?
      end
      node.child_frames.try &.each { |child| seed(child) }
    end

    private def create_isolated_world(frame_id : String, timeout : Time::Span) : Nil
      # Note the protocol's own spelling of "universal".
      @session.execute(CDP::Protocol::Page::CreateIsolatedWorldRequest.new(
        frame_id: frame_id, world_name: @utility_world_name, grant_univeral_access: false), timeout)
    rescue CDP::ProtocolError
      # The frame went away between reading the tree and asking about it, which
      # is a page doing normal things rather than a failure.
    end

    # ------------------------------------------------------------ handlers ---

    private def watch_page : Nil
      @session.on(CDP::Protocol::Page::FrameAttachedEvent) do |event|
        change { upsert_locked(event.frame_id, event.parent_frame_id) }
      end

      # The commit. Not `Page.lifecycleEvent init`, which arrives *before* this
      # and describes a document that does not exist yet — measured.
      @session.on(CDP::Protocol::Page::FrameNavigatedEvent) do |event|
        info = event.frame
        resync = @mutex.synchronize do
          wanted = @resync_on_commit && info.parent_id.nil?
          @resync_on_commit = false if wanted
          wanted
        end
        spawn(name: "resync") { resync_contexts } if resync

        change do
          frame = upsert_locked(info.id, info.parent_id)

          # The frames inside this one belonged to the document being replaced.
          # Chrome announces nothing about them — measured: navigating away
          # from a page with an iframe sends no `frameDetached` at all, while
          # `Page.getFrameTree` immediately afterwards reports no children. A
          # tree that only listened would go on reporting a frame that does not
          # exist, and evaluating in it waits out the whole deadline.
          discard_children_locked(frame)

          frame.commit_locked(info.url, info.name || "", info.loader_id)
        end
      end

      # A same-document navigation: `history.pushState`, or a fragment.
      # Measured: no `frameNavigated`, no lifecycle event, and the loader does
      # not move. So only the address changes here — resetting anything else is
      # what makes `wait_for_load_state(:load)` hang on a single-page app.
      @session.on(CDP::Protocol::Page::NavigatedWithinDocumentEvent) do |event|
        change { @frames[event.frame_id]?.try &.same_document_locked(event.url) }
      end

      @session.on(CDP::Protocol::Page::FrameDetachedEvent) do |event|
        change do
          frame = @frames[event.frame_id]?
          if frame
            frame.subtree_locked.each do |gone|
              gone.detach_locked
              @frames.delete(gone.id)
            end
            frame.parent.try &.orphan_locked(frame)
          end
        end
      end

      @session.on(CDP::Protocol::Page::LifecycleEventEvent) do |event|
        state = LoadState.from_protocol(event.name)
        if state
          change do
            frame = @frames[event.frame_id]?
            # An event carrying a loader the frame is no longer showing belongs
            # to a document that has already been replaced.
            frame.reach_locked(state) if frame && frame.loader_id_locked == event.loader_id
          end
        end
      end

      @session.on(CDP::Protocol::Page::FrameRequestedNavigationEvent) do |event|
        # Child frames announce their own initial navigation, so a barrier that
        # listened to every frame would arm itself on any page with an iframe.
        main, barriers = @mutex.synchronize { {@main_frame, @barriers.dup} }
        if main && main.id == event.frame_id && !barriers.empty?
          loader = @mutex.synchronize { main.loader_id_locked }
          barriers.each(&.arm(event.frame_id, loader))
        end
      end
    end

    private def watch_runtime : Nil
      @session.on(CDP::Protocol::Runtime::ExecutionContextCreatedEvent) do |event|
        description = event.context
        frame_id = description.aux_data.try(&.["frameId"]?).try(&.as_s?)
        if frame_id
          change do
            frame = @frames[frame_id]?
            frame.try &.add_context_locked(ExecutionContext.new(
              @session, description.id, description.unique_id, description.name))
          end
        end
      end

      # Measured: this fires per context when a *child* frame navigates or is
      # removed, and never for a main-frame navigation.
      @session.on(CDP::Protocol::Runtime::ExecutionContextDestroyedEvent) do |event|
        change do
          @frames.each_value do |frame|
            break if frame.remove_context_locked(event.execution_context_id)
          end
        end
      end

      # Measured: this carries no frame id and only ever accompanies a
      # main-frame cross-document navigation, so clearing everything is safe.
      # It is corroboration rather than the mechanism — contexts are retired by
      # the commit, which stays true when this event is absent or late.
      @session.on(CDP::Protocol::Runtime::ExecutionContextsClearedEvent) do |_|
        change { @frames.each_value(&.retire_contexts_locked) }
      end
    end

    private def watch_network : Nil
      @session.on(CDP::Protocol::Network::RequestWillBeSentEvent) do |event|
        frame_id = event.frame_id
        if frame_id
          change do
            frame = @frames[frame_id]?
            if frame
              # A redirect arrives as a second event with the same request id
              # and a `redirectResponse`, and the pair completes once.
              continuation = !event.redirect_response.nil?
              @request_frames[event.request_id] = {frame_id, event.loader_id} unless continuation
              frame.accountant.started(event.request_id, event.loader_id, redirect_continuation: continuation)
            end
          end
        end
      end

      @session.on(CDP::Protocol::Network::LoadingFinishedEvent) { |event| finish(event.request_id) }
      @session.on(CDP::Protocol::Network::LoadingFailedEvent) { |event| finish(event.request_id) }
    end

    # :nodoc:
    #
    # Interception is turned on with the first route and off with the last, so a
    # page nobody is routing pays nothing: with `Fetch` enabled every single
    # request stops and waits for an answer, which is a round trip added to each
    # one.
    protected def add_route(pattern : URLPattern, handler : Route -> Nil, timeout : Time::Span) : Nil
      first = @mutex.synchronize do
        was_empty = @routes.empty?
        @routes << RouteHandler.new(pattern, handler)
        was_empty
      end
      return unless first

      @session.execute(CDP::Protocol::Fetch::EnableRequest.new(
        patterns: [CDP::Protocol::Fetch::RequestPattern.new(url_pattern: "*")]), timeout)
    end

    # :nodoc:
    protected def remove_routes(pattern : URLPattern?, timeout : Time::Span) : Nil
      empty = @mutex.synchronize do
        if pattern
          wanted = pattern.to_s
          @routes.reject! { |handler| handler.pattern.to_s == wanted }
        else
          @routes.clear
        end
        @routes.empty?
      end
      return unless empty

      @session.execute(CDP::Protocol::Fetch::DisableRequest.new, timeout)
    rescue CDP::Error
      # The page is going away, which turns interception off more thoroughly
      # than the command would have.
    end

    # :nodoc:
    #
    # Asks the browser to announce the execution contexts all over again.
    #
    # For a tab that was held still before its first statement. Measured: the
    # contexts of the document such a tab then loads are never announced at all
    # — not late, not on the wrong session, simply absent — and `Runtime.enable`
    # a second time replays nothing, because the agent is already on. Turning it
    # off and on again is what produces the snapshot, and every later navigation
    # in that tab behaves normally.
    #
    # One extra round trip, on the one commit that needs it.
    protected def resync_contexts(timeout : Time::Span = 10.seconds) : Nil
      @session.execute(CDP::Protocol::Runtime::DisableRequest.new, timeout)
      @session.execute(CDP::Protocol::Runtime::EnableRequest.new, timeout)
    rescue CDP::Error
      # The tab went away, which is a different problem and its own error.
    end

    # :nodoc:
    protected def resync_after_first_commit : Nil
      @mutex.synchronize { @resync_on_commit = true }
    end

    # :nodoc:
    #
    # Believes the document about how far it has loaded.
    #
    # For a tab that was already running before anything here subscribed. A
    # `load` that has already fired is not replayed, so a waiter for it waits
    # for an event that is never coming — which is what an adopted popup is:
    # it has to be released before it will answer a command, and by the time it
    # answers, its short first document may be finished.
    #
    # `document.readyState` is the page's own account of the same three states,
    # and it is the only one available after the fact. Only ever used to move
    # forward: the events remain the source of truth for everything that
    # happens from here on.
    protected def seed_load_state(timeout : Time::Span) : Nil
      state = @session.execute(CDP::Protocol::Runtime::EvaluateRequest.new(
        expression: "document.readyState", return_by_value: true), timeout).result.value.try(&.as_s?)
      return unless state

      frame = main_frame
      @mutex.synchronize do
        frame.reach_locked(LoadState::Commit)
        frame.reach_locked(LoadState::DOMContentLoaded) if state == "interactive" || state == "complete"
        frame.reach_locked(LoadState::Load) if state == "complete"
      end
      ring
    end

    private def watch_fetch : Nil
      @session.on(CDP::Protocol::Fetch::RequestPausedEvent) do |event|
        # The browser is holding this request open until somebody answers, and
        # the answer travels over the same connection that delivered the event.
        # A handler run here would be waiting on a fiber that cannot proceed
        # until it returns, and a handler that touches the page — which is most
        # of them — would deadlock outright.
        handlers = @mutex.synchronize { @routes.reverse }
        route = Route.new(@session, event.request_id, event.request, event.resource_type)
        matched = handlers.find(&.handles?(event.request.url))

        spawn(name: "route") { dispatch_route(matched, route, event.request.url) }
      end
    end

    private def dispatch_route(matched : RouteHandler?, route : Route, url : String) : Nil
      matched.call(route) if matched
    rescue error
      Log.error(exception: error) { "a route handler for #{url} raised" }
    ensure
      # An unmatched request, or one whose handler forgot, is let through rather
      # than left hanging: the alternative is a page that waits for its own
      # timeout and looks exactly like a slow server.
      let_through(route) unless route.answered?
    end

    private def let_through(route : Route) : Nil
      route.continue
    rescue CDP::Error
      # The request went away with the page it belonged to.
    end

    # :nodoc:
    #
    # How many requests this manager still has a frame recorded for.
    #
    # Exposed for the soak specs and for nothing else. "Bookkeeping is cleaned
    # up" is otherwise a claim nobody can check, and the map this counts is
    # written once per request for the life of the page.
    def tracked_requests : Int32
      @mutex.synchronize { @request_frames.size }
    end

    private def finish(request_id : String) : Nil
      change do
        if entry = @request_frames.delete(request_id)
          @frames[entry[0]]?.try(&.accountant.finished(request_id))
        end
      end
    end

    # :nodoc:
    #
    # Drops what this frame's previous document was still waiting for.
    #
    # The mirror of `NetworkAccountant#restart`, and needed for the same reason:
    # Chrome never mentions an abandoned request again, so an entry made for one
    # stays for the life of the page. Measured before it was fixed — thirty
    # navigations that each abandoned one request left thirty-nine entries here
    # while the tally itself sat at four.
    #
    # Only this frame's, and only the documents that are not the one committing:
    # a sibling frame's requests belong to a loader of its own and are none of
    # this commit's business.
    protected def forget_abandoned(frame_id : String, loader_id : String) : Nil
      @request_frames.reject! { |_, entry| entry[0] == frame_id && entry[1] != loader_id }
    end

    # ------------------------------------------------------------- plumbing --

    # Drops a frame's children and everything under them.
    #
    # Not the frame itself: a frame survives its documents, and this is called
    # when one of them is replaced.
    private def discard_children_locked(frame : Frame) : Nil
      frame.child_frames_locked.each do |child|
        child.subtree_locked.each do |gone|
          gone.detach_locked
          @frames.delete(gone.id)
        end
        frame.orphan_locked(child)
      end
    end

    private def upsert_locked(id : String, parent_id : String?) : Frame
      existing = @frames[id]?
      return existing if existing

      parent = parent_id.try { |pid| @frames[pid]? }
      frame = Frame.new(self, @mutex, id, parent)
      @frames[id] = frame
      parent.try &.adopt_locked(frame)
      frame
    end

    # Applies a change under the lock, then wakes everything waiting.
    #
    # The ring is deliberately outside the lock: it takes the lock itself to
    # copy the waiter list, and `Sync::Mutex` is not reentrant.
    private def change(&) : Nil
      @mutex.synchronize { yield }
      ring
    end

    # Wakes every waiter without ever blocking the event fiber.
    #
    # Each waiter has its own single-slot channel. One shared channel would
    # wake exactly one of them, and the rest would sit out their whole deadline
    # before looking again — which is a stall, not a race, and therefore the
    # kind of bug that gets diagnosed as "the browser was slow".
    private def ring : Nil
      waiters = @mutex.synchronize { @waiters.dup }
      waiters.each do |channel|
        select
        when channel.send(nil)
        else
        end
      end
    end

    # A round trip that does nothing, so that whatever the action queued ahead
    # of it has been processed by the time it comes back.
    private def input_action_epilogue : Nil
      @session.execute(CDP::Protocol::Page::EnableRequest.new, 5.seconds)
    rescue CDP::Error
      # The page went away mid-action. The caller is about to find that out in
      # a more useful way than this could report it.
    end

    private def settle(barrier : SignalBarrier, progress : Progress) : Nil
      expectations = barrier.expectations
      return if expectations.empty?

      grace = Progress.new(progress.operation, {progress.remaining, SignalBarrier::GRACE}.min)
      expectations.each do |frame_id, was|
        frame = @mutex.synchronize { @frames[frame_id]? }
        next unless frame

        begin
          progress.log("a navigation was announced by #{frame_id}; waiting for it")
          wait_until(grace, "the announced navigation to commit") do
            frame.detached? || frame.loader_id != was
          end
        rescue TimeoutError
          # Announced and never landed. A navigation can be cancelled after it
          # is announced — `beforeunload`, a handler calling `preventDefault`,
          # a link that turns out to be a download — so this is an outcome and
          # not a failure of the action that triggered it.
          progress.log("the announced navigation did not commit within #{SignalBarrier::GRACE}")
        end
      end
    end
  end
end
