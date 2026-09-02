require "./spec_helper"
require "./support/playwright_source"

# Level 4: the same question asked of this shard and of Playwright.
#
# Visibility is where a port drifts without noticing. The rule reads like a
# rectangle check and is not one — `opacity: 0` is visible, `display: contents`
# has no box of its own, `visibility: hidden` is inherited but can be turned
# back on by a descendant — and every one of those is a place where a
# reimplementation quietly answers differently from the thing it was copied
# from, for years, until somebody's test clicks the wrong element.
#
# Nothing of Playwright's is vendored here. Its source is read at spec time from
# wherever it is installed, and this spec is pending when there is no copy. No
# Node.js is involved: what runs is the browser's own engine, on both sides.
describe "agreement with Playwright", tags: "integration" do
  expression = PlaywrightSource.visibility_expression

  if CDP::Launcher.executable?.nil?
    pending "needs a browser installed on this machine"
  elsif expression.nil?
    pending "needs a playwright-core to compare against (CRYSTALWRIGHT_PLAYWRIGHT_BUNDLE)"
  else
    source = expression

    it "agrees about every element on the visibility fixture" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/visibility.html"))

          # Their implementation, run in the page by the page's own engine.
          loaded = page.evaluate(
            "(text) => { globalThis.__playwrightIsVisible = eval(text); return typeof globalThis.__playwrightIsVisible; }",
            source)
          loaded.as_s.should eq "function"

          cases = %w[
            plain display-none visibility-hidden transparent zero-size off-screen
            inline-nothing inside-hidden shown-again inside-none
            contents-with-text contents-with-element contents-with-hidden contents-empty
            closed-details closed-summary inside-closed-details
            open-details inside-open-details attribute-hidden tiny
          ]

          disagreements = [] of String
          cases.each do |id|
            ours = page.locator("##{id}").visible?
            theirs = page.evaluate(
              "(id) => globalThis.__playwrightIsVisible(document.getElementById(id))", id).as_bool
            disagreements << "##{id}: ours=#{ours} playwright=#{theirs}" unless ours == theirs
          end

          # Reported all at once rather than failing on the first, because the
          # interesting output of a differential run is the whole list.
          disagreements.should eq [] of String
        end
      end
    end

    it "is asking a question that can come out either way" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/visibility.html"))

          # Guard against the comparison above passing because everything is
          # visible, or because nothing is. If the fixture ever stops containing
          # both answers, the agreement it reports means nothing.
          page.locator("#plain").visible?.should be_true
          page.locator("#display-none").visible?.should be_false
          page.locator("#visibility-hidden").visible?.should be_false

          # And the two that a rectangle check would get wrong on its own.
          page.locator("#transparent").visible?.should be_true
          page.locator("#shown-again").visible?.should be_true
        end
      end
    end
  end
end
