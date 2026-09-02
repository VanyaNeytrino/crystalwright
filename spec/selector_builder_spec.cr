require "./spec_helper"

# Level 1: the strings a locator builds, with no browser anywhere.
#
# Worth having as a unit because every bug here is silent. A selector that comes
# out slightly wrong does not fail to compile and does not raise — it matches
# something else, or nothing, and the failure surfaces as "the element was never
# visible" thirty seconds later in a spec about something unrelated.
describe Crystalwright::SelectorBuilder do
  builder = Crystalwright::SelectorBuilder.new

  describe "the steps" do
    it "joins steps with the separator and starts without one" do
      builder.step("#root").selector.should eq "#root"
      builder.step("#root").step(".item").selector.should eq "#root >> .item"
    end

    it "quotes text so that nothing inside it is read as syntax" do
      # The whole point of the quoting. A person writing `text=Save` by hand is
      # fine; a builder handed a string from a page's own content is not, and
      # the failure is silent in both directions — a stray `>>` splits one step
      # into two, and a stray quote swallows the rest.
      builder.by_text("Go >> there", false).selector.should eq %(text="Go >> there"i)
      builder.by_text(%(He said "no")).selector.should eq %(text="He said \\"no\\""i)
      builder.by_text("back\\slash").selector.should eq %(text="back\\\\slash"i)
      builder.by_text("line\nbreak").selector.should eq %(text="line\\nbreak"i)
    end

    it "distinguishes exact from a case-insensitive substring by a flag" do
      builder.by_text("Save", true).selector.should eq %(text="Save")
      builder.by_text("Save", false).selector.should eq %(text="Save"i)
    end

    it "carries a regular expression across with the flags JavaScript spells" do
      builder.by_text(/^Save$/).selector.should eq "text=/^Save$/"
      builder.by_text(/save/i).selector.should eq "text=/save/i"

      # Crystal's `m` is the composite MULTILINE_ONLY | DOTALL, so it is two
      # letters on the other side. Getting this wrong produces a pattern that
      # matches different text and raises nothing anywhere.
      builder.by_text(/a.b/m).selector.should eq "text=/a.b/ms"
    end

    it "refuses a regular expression JavaScript has no letter for" do
      expect_raises(Crystalwright::SerializationError, /no equivalent/) do
        builder.by_text(Regex.new("x", Regex::Options::EXTENDED))
      end
    end

    it "builds the other engines" do
      builder.by_test_id("save").selector.should eq "data-testid=save"
      builder.by_label("Your name", true).selector.should eq %(label="Your name")
      builder.by_placeholder("Type here").selector.should eq %(placeholder="Type here"i)
      builder.by_alt_text("A photo").selector.should eq %(alt="A photo"i)
      builder.by_title("the field").selector.should eq %(title="the field"i)
    end
  end

  describe "narrowing" do
    it "adds a filter rather than a search" do
      # `.row >> text=Delete` names the button; `.row >> internal:has-text=...`
      # names the row. The difference is the whole reason `filter` is not just
      # another chained step.
      builder.step(".row").narrow(has_text: "Delete").selector
        .should eq %(.row >> internal:has-text="Delete"i)
      builder.step(".row").narrow(has: "button.remove").selector
        .should eq %(.row >> internal:has="button.remove")
      builder.step(".row").narrow(visible: true).selector
        .should eq ".row >> visible=true"
      builder.step(".row").narrow(visible: false).selector
        .should eq ".row >> visible=false"
    end

    it "applies several narrowings in the order they were given" do
      built = builder.step("li").narrow(has_text: "Ada", visible: true)
      built.selector.should eq %(li >> internal:has-text="Ada"i >> visible=true)
    end

    it "quotes a nested selector, because it is data here and not syntax" do
      built = builder.step(".row").narrow(has: %(span >> text="a >> b"))
      built.selector.should eq %(.row >> internal:has="span >> text=\\"a >> b\\"")
    end
  end

  describe "picking one" do
    it "counts from the start, and from the end when negative" do
      builder.step("li").at(0).selector.should eq "li >> nth=0"
      builder.step("li").at(2).selector.should eq "li >> nth=2"
      builder.step("li").at(-1).selector.should eq "li >> nth=-1"
    end
  end

  describe "fuzzing" do
    it "never produces a step that cannot be read back" do
      # Random text through the builder and back out through the same parser the
      # page uses. What is being checked is that the round trip survives — that
      # the body a builder emits parses as exactly one step whose text is the
      # text that went in.
      random = Random.new(20260902)
      # Written out rather than as a `%w` list, which does not process escapes:
      # the earlier version fuzzed the two characters `\` and `n` and never a
      # real newline or a single backslash, which are the two that matter most.
      alphabet = [
        "a", "Z", "0", "\"", "'", "`", "\\", ">", ">>", "=", "/",
        "\n", "\t", "\u0000", "<", "&", "é", "😀",
        "{", "}", "[", "]", "(", ")", ":", ";", ".", "#", "*", "~", "|", "^", "$", "?",
      ]

      2000.times do
        length = random.rand(0..12)
        text = String.build { |io| length.times { io << alphabet.sample(random) } }

        [true, false].each do |exact|
          body = Crystalwright::SelectorBuilder.body(text, exact)

          # One step, whatever is in the text: nothing may be read as a step
          # separator.
          split_steps(%(text=#{body})).size.should eq 1

          # And the quoted half parses back to the text that went in, which is
          # what the page does to it.
          quoted = exact ? body : body[0...-1]
          JSON.parse(quoted).as_s.should eq text
        end
      end
    end
  end
end

# The same rule the injected script splits on, so that a spec cannot pass while
# disagreeing with the page about what a step is.
private def split_steps(selector : String) : Array(String)
  steps = [] of String
  start = 0
  quote = nil.as(Char?)
  depth = 0
  index = 0

  while index < selector.size
    character = selector[index]
    if quote
      if character == '\\'
        index += 1
      elsif character == quote
        quote = nil
      end
    elsif character == '"' || character == '\'' || character == '`'
      quote = character
    elsif character == '(' || character == '['
      depth += 1
    elsif character == ')' || character == ']'
      depth -= 1
    elsif depth.zero? && character == '>' && selector[index + 1]? == '>'
      steps << selector[start...index]
      index += 1
      start = index + 1
    end
    index += 1
  end

  steps << selector[start..]
  steps.map(&.strip).reject(&.empty?)
end
