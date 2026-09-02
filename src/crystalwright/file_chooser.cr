require "cdp"
require "./errors"

module Crystalwright
  # A file picker the page has opened and is waiting on.
  #
  # Measured: `Page.fileChooserOpened` only arrives for a *trusted* input event.
  # An `element.click()` run from JavaScript opens no chooser at all, because
  # there is no user activation behind it — so the only way to reach this is
  # through an action that dispatches real input, which is what `click` does.
  class FileChooser
    # Whether the page will take more than one file.
    getter? multiple : Bool

    # :nodoc:
    def initialize(@session : CDP::Session, @backend_node_id : Int32, @multiple : Bool)
    end

    # Hands the page these files.
    def set_files(*paths : String, timeout : Time::Span = 10.seconds) : Nil
      set_files(paths.to_a, timeout)
    end

    # :ditto:
    def set_files(paths : Array(String), timeout : Time::Span = 10.seconds) : Nil
      if paths.size > 1 && !multiple?
        raise Error.new("This input takes one file and #{paths.size} were given. \
                         Add the `multiple` attribute, or pass one path.")
      end

      missing = paths.reject { |path| File.exists?(path) }
      raise Error.new("No such file: #{missing.join(", ")}") unless missing.empty?

      @session.execute(CDP::Protocol::DOM::SetFileInputFilesRequest.new(
        files: paths.map { |path| File.expand_path(path) },
        backend_node_id: @backend_node_id), timeout)
    end
  end
end
