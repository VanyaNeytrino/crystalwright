require "./spec_helper"

# Level 1: which addresses a pattern names, with nothing else involved.
#
# Worth having as a unit because the failure mode is silent and one-directional:
# a pattern that matches too little makes a route not fire, which is noticed
# immediately, and a pattern that matches too much makes it fire on somebody
# else's request, which is not noticed at all.
describe Crystalwright::URLPattern do
  matches = ->(glob : String, url : String) { Crystalwright::URLPattern.new(glob).matches?(url) }

  it "treats one star as one segment and two as any number" do
    matches.call("**/api/*", "https://a.test/v1/api/users").should be_true
    matches.call("**/api/*", "https://a.test/api/users").should be_true

    # One star does not cross a slash, so this has one segment too many.
    matches.call("**/api/*", "https://a.test/api/users/1").should be_false
    matches.call("**/api/**", "https://a.test/api/users/1").should be_true
  end

  it "escapes the dots, which is the whole reason not to write these by hand" do
    # The version people write by hand leaves the dots alone, and then the
    # pattern for one host quietly matches every host that has those letters
    # somewhere. In a route that fulfils requests that is not a typo.
    matches.call("https://a.test/**", "https://a.test/x").should be_true
    matches.call("https://a.test/**", "https://aXtest/x").should be_false
    matches.call("https://a.test/**", "https://evil.test/a.test/x").should be_false
  end

  it "anchors at both ends" do
    matches.call("**/login", "https://a.test/login").should be_true
    matches.call("**/login", "https://a.test/deep/login").should be_true

    # Anchored at the end, so nothing may follow.
    matches.call("**/login", "https://a.test/login/extra").should be_false

    # And the slash before it is a literal slash rather than decoration, so a
    # path that merely ends in the word does not match.
    matches.call("**/login", "https://a.test/xlogin").should be_false
  end

  it "offers a choice between alternatives" do
    matches.call("**/*.{png,jpg}", "https://a.test/i/cat.png").should be_true
    matches.call("**/*.{png,jpg}", "https://a.test/i/cat.jpg").should be_true
    matches.call("**/*.{png,jpg}", "https://a.test/i/cat.gif").should be_false
  end

  it "matches exactly one character for a question mark" do
    matches.call("**/v?/**", "https://a.test/v1/x").should be_true
    matches.call("**/v?/**", "https://a.test/v12/x").should be_false
  end

  it "keeps the query string and the fragment in the address it is matching" do
    # A pattern is matched against the whole URL, so a query is text like any
    # other and has to be spelled out to be matched.
    matches.call("**/search", "https://a.test/search?q=1").should be_false
    matches.call("**/search?*", "https://a.test/search?q=1").should be_true
    matches.call("**/page#*", "https://a.test/page#section").should be_true
  end

  it "leaves a comma alone outside a choice" do
    matches.call("**/a,b", "https://a.test/a,b").should be_true
  end

  it "says so when a choice is never closed" do
    expect_raises(Crystalwright::Error, /unclosed/) do
      Crystalwright::URLPattern.new("**/*.{png")
    end
  end

  it "takes a regular expression as it is" do
    Crystalwright::URLPattern.new(/\/api\/\d+$/).matches?("https://a.test/api/42").should be_true
    Crystalwright::URLPattern.new(/\/api\/\d+$/).matches?("https://a.test/api/x").should be_false
  end
end
