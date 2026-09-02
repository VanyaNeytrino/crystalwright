require "spec"
require "../src/crystalwright"

# The runtime's default execution context has a parallelism of one, so fibers
# interleave but never actually run at the same time. Setting this raises it,
# which is the only configuration where shared state can genuinely race. CI runs
# the suite both ways, for the reason recorded in `cdp.cr`'s M1 worklog: the
# missing send mutex survived twenty thousand commands at the default.
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
