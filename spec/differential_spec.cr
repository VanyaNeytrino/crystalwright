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

    # And the same question for roles and names, which is where a `get_by_role`
    # drifts. There is no shortcut here: a role is about seventy rules and a
    # name is an algorithm with a visited set in it, and "nearly right" means a
    # locator that finds the button on the page it was written against and
    # stops finding it on the next one. Agreement is a number rather than an
    # opinion, and the fixture is built to disagree.
    it "agrees about the role and the name of every element on the roles fixture" do
      aria = PlaywrightSource.aria_expression
      next if aria.nil?

      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/roles.html"))
          loaded = page.evaluate(
            "(text) => { globalThis.__playwrightAria = eval(text); return typeof globalThis.__playwrightAria.role; }",
            aria)
          loaded.as_s.should eq "function"

          theirs = page.evaluate(<<-JS).as_a
            () => [...document.querySelectorAll("body *")].map((element) => {
              const name = globalThis.__playwrightAria.name(element);
              return {
                role: globalThis.__playwrightAria.role(element) || "",
                name: (name && name.text !== undefined) ? name.text : String(name),
                hidden: globalThis.__playwrightAria.hidden(element),
              };
            })
            JS
          described = page.evaluate(<<-JS).as_a
            () => [...document.querySelectorAll("body *")].map((element) =>
              element.outerHTML.replace(/s+/g, " ").slice(0, 70))
            JS

          handles = page.query_selector_all("body *")
          begin
            roles = handles.map(&.aria_role.to_s)
            names = handles.map(&.accessible_name)
          ensure
            handles.each(&.dispose)
          end

          handles.size.should eq theirs.size
          handles.size.should be > 100

          disagreements = [] of String
          theirs.each_with_index do |expected, index|
            unless expected["role"].as_s == roles[index]
              disagreements << "role of #{described[index].as_s}: " \
                               "ours=#{roles[index].inspect} playwright=#{expected["role"].as_s.inspect}"
            end
            unless expected["name"].as_s == names[index]
              disagreements << "name of #{described[index].as_s}: " \
                               "ours=#{names[index].inspect} playwright=#{expected["name"].as_s.inspect}"
            end
          end
          disagreements.should eq [] of String

          # And that the queries built on those two answers select the same
          # elements. Roles and names agreeing element by element does not by
          # itself mean `get_by_role` agrees: the hidden rule and the name
          # comparison are its own.
          theirs.map(&.["role"].as_s).reject(&.empty?).uniq!.each do |role|
            visible = theirs.count { |e| e["role"].as_s == role && !e["hidden"].as_bool }
            page.get_by_role(role).count.should eq visible
          end

          theirs.each do |element|
            name = element["name"].as_s
            role = element["role"].as_s
            next if name.empty? || role.empty? || element["hidden"].as_bool
            page.get_by_role(role, name: name, exact: true).count.should be > 0
          end
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
