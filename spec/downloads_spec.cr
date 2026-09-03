require "./spec_helper"
require "file_utils"

# Level 3: downloads, the file picker and popups. Dialogs, which belong with
# these, were done two milestones ago because enabling the `Page` domain made
# them urgent then.
describe "downloads, pickers and popups", tags: "integration" do
  if CDP::Launcher.executable?.nil?
    pending "needs a browser installed on this machine"
  else
    describe "downloading" do
      it "catches the file and keeps the page's name out of the path" do
        with_fixtures do |server|
          Crystalwright.launch do |browser|
            browser.new_page do |page|
              page.goto(server.url("/download.html"))

              download = page.expect_download(15.seconds) do
                page.click("#go", timeout: 10.seconds)
              end

              File.read(download.path).should eq "the payload"

              # The server offered `filename="../../evil.txt"`. Measured: Chrome
              # cleans the suggestion itself — it arrives as `_.._evil.txt`, so
              # the dots survive as ordinary characters and the separators do
              # not — and the file on disk is named by its identifier anyway. So
              # nothing the page says can move the file out of the directory
              # this shard chose.
              #
              # The property is "one path component", not "no dots": a file
              # called `report..pdf` is nobody's attack.
              download.suggested_filename.should eq File.basename(download.suggested_filename)
              download.suggested_filename.should_not contain "/"
              download.suggested_filename.should_not contain "\\"
              File.dirname(download.path).should eq browser.downloads_path
            end
          end
        end
      end

      it "will not let a suggested name climb out of a directory" do
        # Where the danger actually is. Chrome protects its own download
        # directory; nothing protects a caller who builds a path out of the name
        # the page suggested, which is what `save_into` is for.
        Crystalwright::Download.safe_name("../../evil.txt").should eq "evil.txt"
        Crystalwright::Download.safe_name("..\\\\..\\\\evil.txt").should eq "evil.txt"
        Crystalwright::Download.safe_name("/etc/passwd").should eq "passwd"
        Crystalwright::Download.safe_name("...").should eq "download"
        Crystalwright::Download.safe_name("").should eq "download"
        Crystalwright::Download.safe_name("report 2026.pdf").should eq "report_2026.pdf"
      end

      it "keeps save_into inside the directory it was given" do
        # The helper above is not the thing that matters; this is. A download
        # whose suggested name climbs out has to land inside anyway, and the
        # only way to get such a name is to build one, because Chrome cleans
        # what a real server sends before this shard ever sees it.
        source = File.join(Dir.tempdir, "cw-src-#{Random::Secure.hex(4)}")
        into = File.join(Dir.tempdir, "cw-into-#{Random::Secure.hex(4)}")
        outside = File.join(File.dirname(into), "evil.txt")

        File.write(source, "the payload")
        File.delete(outside) if File.exists?(outside)

        begin
          hostile = Crystalwright::Download.new("http://a.test/x", "../../evil.txt", source)
          saved = hostile.save_into(into)

          File.dirname(saved).should eq into
          File.read(saved).should eq "the payload"
          File.exists?(outside).should be_false
        ensure
          FileUtils.rm_rf(into)
          File.delete(source) if File.exists?(source)
          File.delete(outside) if File.exists?(outside)
        end
      end

      it "saves the file where it is told" do
        with_fixtures do |server|
          Crystalwright.launch do |browser|
            browser.new_page do |page|
              page.goto(server.url("/download.html"))
              download = page.expect_download(15.seconds) { page.click("#go", timeout: 10.seconds) }

              into = File.join(Dir.tempdir, "cw-spec-#{Random::Secure.hex(4)}")
              begin
                saved = download.save_into(into)
                File.read(saved).should eq "the payload"
                File.dirname(saved).should eq into
              ensure
                FileUtils.rm_rf(into)
              end
            end
          end
        end
      end
    end

    describe "the file picker" do
      it "hands files to an input without opening anything" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/filechooser.html"))

            sample = File.join(Dir.tempdir, "cw-sample-#{Random::Secure.hex(4)}.txt")
            File.write(sample, "contents")
            begin
              page.set_input_files("#one", sample)
              Crystalwright.expect(page.locator("#picked")).to_have_text(File.basename(sample))
            ensure
              File.delete(sample)
            end
          end
        end
      end

      it "answers a picker the page opened" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/filechooser.html"))

            first = File.join(Dir.tempdir, "cw-a-#{Random::Secure.hex(4)}.txt")
            second = File.join(Dir.tempdir, "cw-b-#{Random::Secure.hex(4)}.txt")
            File.write(first, "a")
            File.write(second, "b")

            begin
              # A real click, because a picker only opens for a user gesture.
              # Measured: `element.click()` from JavaScript opens nothing at
              # all, which makes this one of the places the actionability work
              # is load-bearing rather than convenient.
              chooser = page.expect_file_chooser(10.seconds) do
                page.click("#many", timeout: 8.seconds)
              end

              chooser.multiple?.should be_true
              chooser.set_files([first, second])
              Crystalwright.expect(page.locator("#picked"))
                .to_have_text("#{File.basename(first)}, #{File.basename(second)}")
            ensure
              File.delete(first)
              File.delete(second)
            end
          end
        end
      end

      it "refuses more files than the input takes" do
        with_fixtures do |server|
          with_page do |page|
            page.goto(server.url("/filechooser.html"))
            chooser = page.expect_file_chooser(10.seconds) { page.click("#one", timeout: 8.seconds) }
            chooser.multiple?.should be_false

            expect_raises(Crystalwright::Error, /takes one file/) do
              chooser.set_files(["a.txt", "b.txt"])
            end
          end
        end
      end
    end

    describe "popups" do
      it "catches a tab the page opened and drives it" do
        with_fixtures do |server|
          Crystalwright.launch do |browser|
            browser.new_page do |page|
              page.goto(server.url("/popup.html"))

              popup = page.expect_popup(15.seconds) do
                page.evaluate("() => window.__open()")
              end

              popup.wait_for_load_state(Crystalwright::LoadState::Load, 10.seconds)
              popup.text_content("#who").should eq "the popup"
              popup.url.should end_with "/popped.html"
            end
          end
        end
      end

      it "catches one opened by following a link, not only by window.open" do
        with_fixtures do |server|
          Crystalwright.launch do |browser|
            # The init script is registered here so that the ordering is under
            # test too: for a tab that has to be released before it will answer
            # anything, "send in order and do not wait" is the only way to have
            # both, and getting it wrong loses one or the other.
            browser.add_init_script("window.__marker = 'ours was first';")

            browser.new_page do |page|
              page.goto(server.url("/popup.html"))

              # Every popup spec here used `window.open`, and that is the one
              # shape that worked. A tab opened by following a link lives in a
              # renderer process of its own, and a process of its own held at
              # `waitForDebuggerOnStart` answers nothing at all until it is
              # released — so setting it up before releasing it waited for a
              # reply that could not come until the wait ended. Measured
              # against a real site first, then reproduced here in 266 ms.
              popup = page.expect_popup(15.seconds) { page.click("#go") }

              popup.wait_for_load_state(Crystalwright::LoadState::Load, 10.seconds)
              popup.url.should end_with "/popped.html"
              popup.text_content("#who").should eq "the popup"
              popup.evaluate(String, "() => window.__marker").should eq "ours was first"
            end
          end
        end
      end

      it "has its script in place before the page's first statement" do
        with_fixtures do |server|
          Crystalwright.launch do |browser|
            # Registered before the tab exists, which is the whole trick. The
            # new target is held still before its first statement, given this,
            # and only then released.
            browser.add_init_script("window.__marker = 'ours was first';")

            browser.new_page do |page|
              page.goto(server.url("/popup.html"))
              popup = page.expect_popup(15.seconds) { page.evaluate("() => window.__open()") }
              popup.wait_for_load_state(Crystalwright::LoadState::Load, 10.seconds)

              # The popup's own script asked, as its first statement, whether the
              # marker was already there. This is the only way to prove the
              # ordering: everything else about a popup looks identical whether
              # the init script arrived first or not.
              popup.evaluate("() => window.__markerWasAlreadyThere").as_bool.should be_true
              popup.evaluate(String, "() => window.__marker").should eq "ours was first"
            end
          end
        end
      end
    end
  end
end

# The smaller things: a picture of the page, the size it thinks it has, the
# cookies it holds, and being told where it is.
describe "the browser's other knobs", tags: "integration" do
  if CDP::Launcher.executable?.nil?
    pending "needs a browser installed on this machine"
  else
    it "takes a picture of the page" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/selectors.html"))
          shot = page.screenshot

          # A PNG, and not an empty one. Comparing pixels would be a spec about
          # font rendering on this machine, which is a different subject and a
          # famously unhappy one.
          shot.size.should be > 1000
          shot[0, 4].should eq Bytes[0x89, 0x50, 0x4E, 0x47]
        end
      end
    end

    it "writes the picture where it is told" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/plain.html"))
          into = File.join(Dir.tempdir, "cw-shot-#{Random::Secure.hex(4)}", "page.png")
          begin
            page.screenshot(path: into)
            File.exists?(into).should be_true
            File.size(into).should be > 1000
          ensure
            FileUtils.rm_rf(File.dirname(into))
          end
        end
      end
    end

    it "tells the page how big it is" do
      with_fixtures do |server|
        with_page do |page|
          page.goto(server.url("/plain.html"))
          page.set_viewport(640, 480)
          page.evaluate(Int32, "() => window.innerWidth").should eq 640
          page.evaluate(Int32, "() => window.innerHeight").should eq 480
        end
      end
    end

    it "keeps and forgets cookies" do
      with_fixtures do |server|
        Crystalwright.launch do |browser|
          browser.new_page do |page|
            page.goto(server.url("/plain.html"))
            page.evaluate("() => { document.cookie = 'seen=yes; path=/'; return 1; }")

            found = browser.cookies.find { |cookie| cookie.name == "seen" }
            found.should_not be_nil
            found.try(&.value).should eq "yes"

            browser.clear_cookies
            browser.cookies.any? { |cookie| cookie.name == "seen" }.should be_false

            browser.add_cookies([CDP::Protocol::Network::CookieParam.new(
              name: "restored", value: "from a saved session", domain: "127.0.0.1", path: "/")])
            page.goto(server.url("/plain.html"))
            page.evaluate(String, "() => document.cookie").should contain "restored"
          end
        end
      end
    end

    it "answers a page that asks where it is" do
      with_fixtures do |server|
        Crystalwright.launch do |browser|
          browser.grant_permissions(["geolocation"], origin: "http://127.0.0.1:#{server.port}")
          browser.new_page do |page|
            page.goto(server.url("/plain.html"))
            page.set_geolocation(55.7558, 37.6173)

            here = page.evaluate(<<-JS, timeout: 10.seconds)
              () => new Promise((resolve) => {
                navigator.geolocation.getCurrentPosition(
                  (p) => resolve([p.coords.latitude, p.coords.longitude]),
                  (e) => resolve(["error", e.message])
                );
              })
              JS

            here[0].as_f.should be_close(55.7558, 0.001)
            here[1].as_f.should be_close(37.6173, 0.001)
          end
        end
      end
    end
  end
end
