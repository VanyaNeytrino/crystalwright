require "./spec_helper"

# Level 1: the rule for "the network has gone quiet", with no browser in it.
#
# Worth having as a unit even though `navigation_spec.cr` drives the real thing,
# because three of the edges cannot be asked of Chrome on demand — a redirect
# that reuses its request id, a request that fails rather than finishes, and a
# document that commits while its own request is still in the air. Level 1 only
# proves this bookkeeping and never Chrome's ordering — that these are the
# events which actually arrive, and in this shape, is what the browser specs in
# `navigation_spec.cr` are for.
describe Crystalwright::NetworkAccountant do
  window = 500.milliseconds

  it "is quiet from the start, once the window has passed" do
    base = Time.instant
    accountant = Crystalwright::NetworkAccountant.new(window, now: base)

    accountant.idle?(base).should be_false
    accountant.idle?(base + 499.milliseconds).should be_false
    accountant.idle?(base + 500.milliseconds).should be_true
  end

  it "is not quiet while anything is in flight, however long it takes" do
    base = Time.instant
    accountant = Crystalwright::NetworkAccountant.new(window, now: base)

    accountant.started("a", "L")
    accountant.in_flight.should eq 1
    accountant.idle?(base + 1.hour).should be_false
    accountant.idle_in(base + 1.hour).should be_nil
  end

  it "starts the window at the last completion, not the first" do
    base = Time.instant
    accountant = Crystalwright::NetworkAccountant.new(window, now: base)

    accountant.started("a", "L")
    accountant.started("b", "L")
    accountant.finished("a", base + 100.milliseconds)

    # One of two finished. Quiet has not begun.
    accountant.idle?(base + 700.milliseconds).should be_false

    accountant.finished("b", base + 600.milliseconds)
    accountant.idle?(base + 1000.milliseconds).should be_false
    accountant.idle?(base + 1100.milliseconds).should be_true
  end

  it "counts a redirect as one request and not two" do
    base = Time.instant
    accountant = Crystalwright::NetworkAccountant.new(window, now: base)

    # Measured against Chrome: the redirect arrives as a second
    # requestWillBeSent carrying the same id and a redirectResponse, and the
    # pair produces exactly one loadingFinished. Counting both leaves the tally
    # permanently one short of draining, so the page never goes quiet again.
    accountant.started("same-id", "L")
    accountant.started("same-id", "L", redirect_continuation: true)
    accountant.in_flight.should eq 1

    accountant.finished("same-id", base + 10.milliseconds)
    accountant.in_flight.should eq 0
    accountant.idle?(base + 600.milliseconds).should be_true
  end

  it "treats a failure as a completion" do
    base = Time.instant
    accountant = Crystalwright::NetworkAccountant.new(window, now: base)

    # `loadingFailed` and `loadingFinished` are the same event to this: a
    # request that was refused is a request that is no longer in the air, and
    # waiting for a failed request to succeed is waiting forever.
    accountant.started("doomed", "L")
    accountant.finished("doomed", base)
    accountant.idle?(base + 500.milliseconds).should be_true
  end

  it "ignores a completion for something it never saw begin" do
    base = Time.instant
    accountant = Crystalwright::NetworkAccountant.new(window, now: base)

    accountant.started("known", "L")
    accountant.finished("never-seen", base + 100.milliseconds)

    # The stray completion must not be taken for the real one.
    accountant.in_flight.should eq 1
    accountant.idle?(base + 1.hour).should be_false
  end

  it "keeps counting the document's own request across the commit" do
    base = Time.instant
    accountant = Crystalwright::NetworkAccountant.new(window, now: base)

    # The commit lands between requestWillBeSent and loadingFinished for the
    # document itself. Emptying the set here would call the network quiet while
    # the page is still downloading.
    accountant.started("the-document", "new-loader")
    accountant.restart("new-loader", base + 20.milliseconds)
    accountant.in_flight.should eq 1
    accountant.idle?(base + 2.seconds).should be_false

    accountant.finished("the-document", base + 100.milliseconds)
    accountant.idle?(base + 600.milliseconds).should be_true
  end

  it "forgets what the abandoned document was still waiting for" do
    base = Time.instant
    accountant = Crystalwright::NetworkAccountant.new(window, now: base)

    # The old document asked for something that will never arrive. Chrome does
    # not report it as finished and does not report it as failed — measured,
    # after a real page would not go idle — so nothing else will ever take it
    # out of the tally. Keeping it makes `networkidle` unreachable for the rest
    # of the frame's life, one navigation after the page that caused it.
    accountant.started("orphan", "old-loader")
    accountant.started("the-document", "new-loader")

    accountant.restart("new-loader", base + 20.milliseconds)

    # The committing document's own request survives; the orphan does not.
    accountant.in_flight.should eq 1
    accountant.finished("the-document", base + 100.milliseconds)
    accountant.idle?(base + 600.milliseconds).should be_true
  end

  it "says how long until it goes quiet, so a waiter knows when to look" do
    base = Time.instant
    accountant = Crystalwright::NetworkAccountant.new(window, now: base)

    # Nothing announces idleness — it arrives through the clock — so a waiter
    # that only listened for events would sleep through it.
    accountant.idle_in(base).should eq 500.milliseconds
    accountant.idle_in(base + 400.milliseconds).should eq 100.milliseconds
    accountant.idle_in(base + 900.milliseconds).should eq Time::Span.zero

    accountant.started("a", "L")
    accountant.idle_in(base).should be_nil
  end
end
