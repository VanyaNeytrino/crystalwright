require "spec"
require "../src/crystalwright"

# The runtime's default execution context has a parallelism of one, so fibers
# interleave but never actually run at the same time. Setting this raises it,
# which is the only configuration where shared state can genuinely race. CI runs
# the suite both ways because the difference is not theoretical: a missing mutex
# in the shard below survived twenty thousand commands at the default and failed
# instantly with this set.
if workers = ENV["CRYSTALWRIGHT_SPEC_PARALLEL"]?.try &.to_i?
  Fiber::ExecutionContext.default.resize(workers)
end

require "./support/fixture_server"

# Waits for a condition instead of sleeping for a guess.
#
# Nothing in this suite may synchronise with `sleep`: a sleep that is long
# enough on a quiet laptop is not long enough on a loaded CI runner, which is
# how a suite starts needing to be run twice.
def eventually(timeout : Time::Span = 2.seconds, message : String = "condition was never met", &) : Nil
  deadline = Time.instant + timeout
  until yield
    raise message if Time.instant > deadline
    Fiber.yield
  end
end

# The budget for an action that is meant to time out.
#
# These specs assert what the failure *says*, never how long it took, so this
# number is a bound that keeps the suite quick rather than a claim about the
# machine. It still has to hold at least one complete attempt — two, for the one
# that reads the retry log — because the message only names what was wrong if
# the library got far enough to find out. When it does not, the message
# describes the deadline expiring inside a protocol round trip instead, and the
# assertion fails while the library is correct.
#
# That is not hypothetical: it is how the suite went red on the sixth of ten
# runs, with a click that never reached its own diagnosis.
#
# Measured on `covered.html`: one full attempt costs about 220 ms, and 2 seconds
# bought nine of them — the same nine idle and under twice as many CPU spinners
# as this machine has cores, so ordinary load is not what broke it. The run that
# failed needed a single round trip to stall for 1.9 s, which is a stall rather
# than slowness. No constant survives an unbounded one, so this is headroom with
# a number behind it, not a proof; the debt is recorded in `docs/NEXT.md`.
DOOMED_ACTION = 5.seconds

# Opens a browser and one tab, and always closes both.
def with_page(&)
  Crystalwright.launch do |browser|
    browser.new_page do |page|
      yield page
    end
  end
end

# The frame with this name, once it is showing a document of its own.
#
# A child frame commits a throwaway `about:blank` before it commits the document
# its `src` names — measured — so "the frame exists" is not the same question as
# "the frame is ready to be asked anything", and a spec that only waits for the
# first one is asking the wrong frame.
def frame_named(page : Crystalwright::Page, name : String, timeout : Time::Span = 5.seconds) : Crystalwright::Frame
  deadline = Time.instant + timeout
  loop do
    found = page.frame(name)
    return found if found && !found.loader_id.empty? && !found.url.empty? && found.url != "about:blank"
    raise "the frame named #{name.inspect} never appeared; saw #{page.frames.map(&.name).inspect}" if Time.instant > deadline
    Fiber.yield
  end
end
