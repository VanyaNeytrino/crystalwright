# A Playwright-style browser automation API for Crystal.
#
# The pieces compose in this order:
#
#   1. `CDP::Session`, from the shard below, carries typed commands and typed
#      events to one target. Nothing here talks to a transport, which is the
#      seam that keeps the protocol details out of this layer entirely.
#   2. `Crystalwright::ExecutionContext` is one JavaScript world in one frame —
#      the page's own, or the isolated one this library works in.
#   3. `Crystalwright::JSHandle` is a live reference to a value that stayed in
#      the page. `Crystalwright::JSValue` is a copy of one that came out, and
#      unlike JSON it can carry `undefined`, `-0`, `Date`, `Map`, `Set` and a
#      value that contains itself.
#   4. `Crystalwright::Page` and `Crystalwright::Browser` own the sessions.
#
# ```
# Crystalwright.launch do |browser|
#   browser.new_page do |page|
#     page.goto("https://example.com")
#     puts page.evaluate(String, "() => document.title")
#   end
# end
# ```
require "cdp"

require "./crystalwright/errors"
require "./crystalwright/js_value"
require "./crystalwright/serialization"
require "./crystalwright/progress"
require "./crystalwright/url_pattern"
require "./crystalwright/page_events"
require "./crystalwright/route"
require "./crystalwright/lifecycle"
require "./crystalwright/network_accountant"
require "./crystalwright/execution_context"
require "./crystalwright/input"
require "./crystalwright/js_handle"
require "./crystalwright/element_handle"
require "./crystalwright/locator"
require "./crystalwright/expect"
require "./crystalwright/signal_barrier"
require "./crystalwright/frame"
require "./crystalwright/frame_manager"
require "./crystalwright/page"
require "./crystalwright/browser"

module Crystalwright
  VERSION = "0.1.0"

  # Starts a browser and returns it.
  #
  # Safe with no arguments, because the shard underneath already is: the sandbox
  # stays on, no debugging port is opened at all, and the profile is a fresh
  # directory only this user can read, removed when the browser closes.
  def self.launch(**options) : Browser
    Browser.new(CDP.launch(**options))
  end

  # Starts a browser, yields it, and always closes it.
  def self.launch(**options, &)
    browser = launch(**options)
    begin
      yield browser
    ensure
      browser.close
    end
  end
end
