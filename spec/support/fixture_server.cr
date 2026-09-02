require "http/server"

# Serves the pages in `spec/fixtures/` over loopback, plus the handful of
# behaviours that cannot be expressed as a static file.
#
# Navigation specs need sub-resources that take a known time to arrive, a
# request that never stops repeating, and a redirect. None of those is a file,
# so they are routes; everything else is a file, because a fixture that has to
# be read while debugging a failure should be readable on its own.
#
# Binds in the constructor, so the port is already accepting by the time a spec
# body runs and there is nothing to wait for — no readiness poll, no sleep.
class FixtureServer
  # The port the kernel assigned.
  getter port : Int32

  # Where `spec/fixtures/` is, resolved at compile time.
  #
  # Not relative to the working directory: a spec that only passes when it is
  # run from the shard root is a spec with a trap in it.
  FIXTURE_ROOT = {{ "#{__DIR__}/../fixtures" }}

  CONTENT_TYPES = {
    ".html" => "text/html; charset=utf-8",
    ".js"   => "application/javascript; charset=utf-8",
    ".css"  => "text/css; charset=utf-8",
    ".json" => "application/json; charset=utf-8",
    ".txt"  => "text/plain; charset=utf-8",
  }

  @requests = [] of String
  @last_response_at : Time::Instant?
  @mutex = Sync::Mutex.new

  # `pages` is an escape hatch for a one-off body a spec would rather write
  # inline than keep in a file. A path here wins over a file of the same name.
  def initialize(@pages : Hash(String, String) = {} of String => String)
    @server = HTTP::Server.new do |context|
      request = context.request
      @mutex.synchronize { @requests << request.resource }
      serve(context, request.path, request.query_params)
      @mutex.synchronize { @last_response_at = Time.instant }
    end

    @port = @server.bind_tcp("127.0.0.1", 0).port

    # Also on ::1 where the machine has it. `localhost` is a different site to
    # Chrome and is how a cross-origin fixture is served, and a browser that
    # resolves it to ::1 against an IPv4-only socket gets a connection refused —
    # which looks exactly like process isolation and is not.
    begin
      @server.bind_tcp("::1", @port)
    rescue Socket::Error
    end

    spawn(name: "fixture-server") { @server.listen }
  end

  # The address of one of the served pages.
  def url(path : String) : String
    "http://127.0.0.1:#{@port}#{path}"
  end

  # Every request this server has answered, in order, with its query string.
  def requests : Array(String)
    @mutex.synchronize { @requests.dup }
  end

  # How many times a path has been asked for, ignoring the query string.
  def request_count(path : String) : Int32
    requests.count { |resource| resource == path || resource.starts_with?("#{path}?") }
  end

  # When this server last finished answering something.
  #
  # The reference point a timing spec needs. "Quiet started 500 ms ago" is a
  # statement about the network, and measuring it from when a spec happened to
  # call `goto` measures the machine's load instead.
  def last_response_at : Time::Instant?
    @mutex.synchronize { @last_response_at }
  end

  # Stops serving.
  def close : Nil
    @server.close
  rescue IO::Error
  end

  private def serve(context : HTTP::Server::Context, path : String, query : URI::Params) : Nil
    case path
    when "/slow"
      # A resource that takes a known time to arrive. The delay is the point of
      # the fixture, so it is a sleep here rather than in a spec.
      sleep((query["ms"]?.try(&.to_i?) || 0).milliseconds)
      slow_body(context, query)
    when "/poll"
      context.response.content_type = CONTENT_TYPES[".txt"]
      context.response.print("tick")
    when .starts_with?("/strict-csp/")
      # The same file under a policy that forbids every script the page could
      # load or run. What has to keep working is this library, which never goes
      # through the page's script loader at all.
      context.response.headers["Content-Security-Policy"] =
        "default-src 'none'; script-src 'none'; style-src 'none'; img-src 'none'"
      serve_file(context, path.sub("/strict-csp", ""))
    when "/redirect"
      context.response.status = HTTP::Status::FOUND
      context.response.headers["Location"] = query["to"]? || "/poll"
    else
      if body = @pages[path]?
        context.response.content_type = CONTENT_TYPES[".html"]
        context.response.print(body)
      else
        serve_file(context, path)
      end
    end
  end

  private def slow_body(context : HTTP::Server::Context, query : URI::Params) : Nil
    case query["type"]?
    when "html"
      title = query["title"]? || "slow"
      context.response.content_type = CONTENT_TYPES[".html"]
      context.response.print("<!doctype html><html><head><title>#{title}</title></head><body>#{title}</body></html>")
    when "css"
      context.response.content_type = CONTENT_TYPES[".css"]
      context.response.print("body { color: black; }")
    else
      context.response.content_type = CONTENT_TYPES[".js"]
      context.response.print("window.__slow = (window.__slow || 0) + 1;")
    end
  end

  private def serve_file(context : HTTP::Server::Context, path : String) : Nil
    # A fixture path comes from a spec, not from a page, but a `..` here would
    # still turn this server into a file reader for the whole machine.
    if path.includes?("..") || !path.starts_with?('/')
      context.response.status = HTTP::Status::FORBIDDEN
      context.response.print("no")
      return
    end

    file = File.join(FIXTURE_ROOT, path)
    unless File.file?(file)
      context.response.status = HTTP::Status::NOT_FOUND
      context.response.print("no such fixture: #{path}")
      return
    end

    context.response.content_type = CONTENT_TYPES[File.extname(path)]? || CONTENT_TYPES[".txt"]
    context.response.print(File.read(file))
  end
end

# Runs a block against a server for the given pages, and always shuts it down.
def with_fixtures(pages : Hash(String, String) = {} of String => String, &)
  server = FixtureServer.new(pages)
  begin
    yield server
  ensure
    server.close
  end
end
