require "cdp"
require "./errors"

module Crystalwright
  # A file the browser has downloaded.
  #
  # It arrives in a directory of this shard's choosing, named by the identifier
  # the browser gave it rather than by anything the page suggested. That is not
  # tidiness: the name comes from the page, and a page that suggests
  # `../../../.ssh/authorized_keys` is not an exotic thought.
  #
  # Measured, and it changes where the danger is: Chrome sanitises the suggested
  # name itself — `../../evil.txt` arrives as `_.._evil.txt` — and with the
  # naming behaviour this shard uses, the file on disk is named by its
  # identifier anyway. So nothing the page says can move the file. What the page
  # can still do is talk a *caller* into building a path out of the suggested
  # name, which is why `save_into` exists next to `save_as`.
  class Download
    # The address the file came from.
    getter url : String

    # The name the page asked for, as Chrome cleaned it up.
    #
    # Safe to show a person and not safe to join onto a directory without
    # further thought, which is what `save_into` is for.
    getter suggested_filename : String

    # Where the file actually is.
    getter path : String

    # :nodoc:
    def initialize(@url : String, @suggested_filename : String, @path : String)
    end

    # Copies it where you say.
    #
    # The destination is yours: nothing is sanitised, because you named it.
    def save_as(destination : String) : String
      directory = File.dirname(destination)
      Dir.mkdir_p(directory) unless Dir.exists?(directory)
      File.copy(@path, destination)
      destination
    end

    # Copies it into a directory, under a name that cannot leave it.
    #
    # The suggested name is reduced to its last component and stripped of
    # anything that could climb out, so the result is inside `directory` no
    # matter what the page asked to be called.
    def save_into(directory : String) : String
      Dir.mkdir_p(directory) unless Dir.exists?(directory)
      save_as(File.join(directory, Download.safe_name(@suggested_filename)))
    end

    # Removes the downloaded file.
    def delete : Nil
      File.delete(@path) if File.exists?(@path)
    end

    # The last component of a name the page chose, with nothing left in it that
    # could name somewhere else.
    #
    # `File.basename` alone is not enough on its own account: a name that is
    # entirely dots, or empty, has to become something rather than nothing.
    def self.safe_name(suggested : String) : String
      base = File.basename(suggested.gsub('\\', '/'))
      cleaned = base.gsub(/[^A-Za-z0-9._-]/, "_").lstrip('.')
      cleaned.empty? ? "download" : cleaned
    end
  end
end
