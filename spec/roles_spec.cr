require "./spec_helper"

describe "roles", tags: "integration" do
  describe "the role an element has" do
    it "reads the role a screen reader would report" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/roles.html"))

          # Not the tag name and not the `role` attribute: a computation with
          # about seventy rules in it, and these are the ones a caller trips on.
          element_at(page, "h1").aria_role.should eq "heading"
          element_at(page, "a[href]").aria_role.should eq "link"

          # An anchor with no href is not a link, whatever it looks like.
          element_at(page, %(a[name="anchor"])).aria_role.should be_nil

          # A section only becomes a region once it has a name of its own.
          element_at(page, %(section[aria-label])).aria_role.should eq "region"
          element_at(page, "section:not([aria-label])").aria_role.should be_nil

          # An image with an empty alt and nothing else to say is decoration.
          element_at(page, %(img[alt=""]:not([title]))).aria_role.should eq "presentation"
          element_at(page, %(img[title])).aria_role.should eq "img"

          # And an input's role is its type, except when a datalist turns it
          # into a combobox.
          element_at(page, %(input[type="search"])).aria_role.should eq "searchbox"
          element_at(page, %(input[list])).aria_role.should eq "combobox"
        end
      end
    end

    it "knows a header inside an article is not the page's banner" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/roles.html"))

          # The rule nobody remembers, and the reason `get_by_role("banner")`
          # is worth having: a landmark inside a sectioning element is not one.
          page.get_by_role("banner").count.should eq 1
          element_at(page, "article header").aria_role.should be_nil
        end
      end
    end

    it "refuses a presentation role from an element that is still operable" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/roles.html"))

          element_at(page, %(div[role="none"])).aria_role.should eq "none"

          # `role="presentation"` on something focusable is a contradiction, and
          # the specification resolves it in the user's favour: the element
          # keeps the role it really has.
          element_at(page, %(button[role="presentation"])).aria_role.should eq "button"

          # A `<div>` has no role to keep, so the same contradiction resolves to
          # nothing at all. This is the pair that shows the rule is about the
          # implicit role rather than about focusability.
          element_at(page, %(div[role="presentation"][tabindex])).aria_role.should be_nil
        end
      end
    end

    it "takes the first role that means something" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/roles.html"))

          element_at(page, %(div[role="link button"])).aria_role.should eq "link"

          # Nonsense falls through to the implicit role — which a `<div>` does
          # not have, so this one ends with no role rather than with "generic".
          element_at(page, %(div[role="not-a-real-role"])).aria_role.should be_nil
        end
      end
    end
  end

  describe "the name it would be read out by" do
    it "prefers a reference, then a label, then its own content" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/roles.html"))

          element_at(page, %(button[aria-labelledby]))
            .accessible_name.should eq "Second heading"
          element_at(page, %(button[aria-label]:not([aria-labelledby])))
            .accessible_name.should eq "Labelled by aria"
          element_at(page, "button:not([aria-label]):not([aria-labelledby])")
            .accessible_name.should eq "Plain button"
        end
      end
    end

    it "flattens whitespace the way a screen reader does" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/roles.html"))

          # The markup says "  Whitespace   around   ".
          page.get_by_role("button", name: "Whitespace around", exact: true).count.should eq 1

          # And the caller's own name is flattened the same way, so a name
          # copied out of a wrapped source file still matches.
          page.get_by_role("button", name: "  Whitespace   around  ", exact: true).count.should eq 1
        end
      end
    end

    it "reads a button named only by the image inside it" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/roles.html"))

          page.get_by_role("button", name: "Image inside a button", exact: true).count.should eq 1
        end
      end
    end

    it "takes a fieldset's name from its legend" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/roles.html"))

          # And with the `legend::before` the fixture carries, so this also
          # pins that CSS content counts.
          element_at(page, "fieldset")
            .accessible_name.should eq "Before The legend"
        end
      end
    end
  end

  describe "get_by_role" do
    it "finds by role and by name" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/roles.html"))

          page.get_by_role("heading").count.should eq 3
          page.get_by_role("button", name: "Plain button", exact: true).count.should eq 1
          # Case-insensitive substring unless told otherwise.
          page.get_by_role("button", name: "plain").count.should eq 1
          page.get_by_role("button", name: "plain", exact: true).count.should eq 0
        end
      end
    end

    it "filters on the states a role can be in" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/roles.html"))

          page.get_by_role("checkbox", checked: true).count.should eq 2
          page.get_by_role("button", pressed: true).count.should eq 1
          page.get_by_role("button", expanded: false).count.should eq 1
          page.get_by_role("option", selected: true).count.should be > 0
          page.get_by_role("heading", level: 2).count.should eq 1

          # A native heading level wins over what the element claims.
          page.get_by_role("heading", level: 5).count.should eq 0
          page.get_by_role("heading", level: 3).count.should eq 1
        end
      end
    end

    it "leaves out what a screen reader would not see" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/roles.html"))

          # Three ways of being invisible to assistive technology, and all three
          # have to count: `display:none`, `visibility:hidden`, `aria-hidden`.
          page.get_by_role("button", name: "Hidden by display none").count.should eq 0
          page.get_by_role("button", name: "Hidden by visibility").count.should eq 0
          page.get_by_role("button", name: "Hidden from aria").count.should eq 0

          # But the name is still computed for them, so they can be asked about.
          page.get_by_role("button", name: "Hidden by display none",
            include_hidden: true).count.should eq 1

          # And the rule on its own, with no name to do the work for it. Asking
          # by name only looks like it tests this: a hidden element's name is
          # computed as empty, so the name filter excludes it whether the
          # hidden rule exists or not. This pair is what actually pins it.
          bare = page.get_by_role("button").count
          page.get_by_role("button", include_hidden: true).count.should eq bare + 3
        end
      end
    end

    it "takes a name that would be a selector if it were pasted in" do
      pages = {"/hostile" => <<-HTML}
        <!doctype html><meta charset="utf-8">
        <button aria-label='] [name="other"'>x</button>
        <button aria-label="other">y</button>
        HTML
      with_fixtures(pages) do |server|
        with_page do |page|
          page.goto(server.url("/hostile"))

          # The name travels as JSON inside the selector rather than being
          # pasted into it, so a button with a bracket in its name is a button
          # with an awkward name and not a way to write a different query.
          page.get_by_role("button", name: %(] [name="other"), exact: true).count.should eq 1
        end
      end
    end
  end

  describe "aria states in actionability" do
    it "waits for an element its page says is disabled" do
      pages = {"/aria" => <<-HTML}
        <!doctype html><meta charset="utf-8">
        <div role="toolbar" aria-disabled="true">
          <button id="inherited">Inherited</button>
          <button id="freed" aria-disabled="false">Freed</button>
        </div>
        <div id="ro" role="textbox" aria-readonly="true" contenteditable>fixed</div>
        HTML
      with_fixtures(pages) do |server|
        with_page do |page|
          page.goto(server.url("/aria"))

          # `aria-disabled` is inherited until something says otherwise, which
          # is how one attribute on a toolbar disables everything in it.
          expect_raises(Crystalwright::TimeoutError, /enabled/) do
            page.click("#inherited", timeout: DOOMED_ACTION)
          end
          page.click("#freed", timeout: 5.seconds)

          expect_raises(Crystalwright::TimeoutError, /editable/) do
            page.fill("#ro", "nope", timeout: DOOMED_ACTION)
          end
        end
      end
    end
  end
end
