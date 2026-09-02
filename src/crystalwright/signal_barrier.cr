module Crystalwright
  # A ledger of navigations an action set off, so the action can wait for them.
  #
  # The problem it solves: a click can navigate, and the command that delivered
  # the click returns long before the new document exists. Without something
  # holding the action open, the *next* call races a navigation the previous one
  # started — it resolves a selector in a document that is about to be thrown
  # away, and fails in a way that looks random.
  #
  # The barrier is armed from the event fiber and waited on from the caller's,
  # which is why it only records. Deciding whether a recorded navigation has
  # landed needs the frame tree, so that decision belongs to `FrameManager` and
  # the blocking happens there.
  class SignalBarrier
    # How long a requested navigation gets to commit before it is written off.
    #
    # Playwright's second, kept rather than reasoned about again. A navigation
    # can be cancelled after it is announced — `beforeunload`, a handler calling
    # `preventDefault`, a download — and in those cases nothing ever commits, so
    # the wait has to end on its own.
    GRACE = 1.second

    @expected = {} of String => String
    @mutex = Sync::Mutex.new

    # Records that a frame announced a navigation, with the document it was
    # showing at the time.
    #
    # Called on the event fiber, so it does nothing but write. The first
    # announcement wins: a frame that announces twice before either lands is
    # still one navigation away from being settled, and the earlier document is
    # the one to compare against.
    def arm(frame_id : String, loader_id : String) : Nil
      @mutex.synchronize { @expected[frame_id] ||= loader_id }
    end

    # The frames that announced a navigation, and what they were showing.
    def expectations : Hash(String, String)
      @mutex.synchronize { @expected.dup }
    end

    # Whether anything was announced at all.
    def armed? : Bool
      @mutex.synchronize { !@expected.empty? }
    end
  end
end
