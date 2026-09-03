require "cdp"
require "./errors"
require "./progress"

module Crystalwright
  # A point in the page's own coordinates, in CSS pixels from the top left of
  # the viewport.
  record Point, x : Float64, y : Float64 do
    def to_s(io : IO) : Nil
      io << '(' << x.round(1) << ", " << y.round(1) << ')'
    end
  end

  # Which mouse button an action uses.
  enum MouseButton
    Left
    Middle
    Right

    # :nodoc:
    def to_protocol : CDP::Protocol::Input::MouseButton
      case self
      in Left   then CDP::Protocol::Input::MouseButton::Left
      in Middle then CDP::Protocol::Input::MouseButton::Middle
      in Right  then CDP::Protocol::Input::MouseButton::Right
      end
    end
  end

  # The mouse, in page coordinates.
  #
  # Low level on purpose: it moves and clicks where it is told and checks
  # nothing. Everything that makes a click reliable — waiting for the element to
  # settle, scrolling it out from under a header, refusing to click something
  # covered by an overlay — belongs a layer up, where the element is known.
  class Mouse
    @x = 0.0
    @y = 0.0
    @buttons = Set(MouseButton).new
    @mutex = Sync::Mutex.new

    # :nodoc:
    def initialize(@session : CDP::Session)
    end

    # Where the mouse currently is.
    def position : Point
      @mutex.synchronize { Point.new(@x, @y) }
    end

    # Moves the mouse.
    def move(x : Float64, y : Float64, progress : Progress? = nil) : Nil
      @mutex.synchronize { @x = x; @y = y }
      dispatch(CDP::Protocol::Input::DispatchMouseEventRequestType::MouseMoved, x, y, nil, 0, progress)
    end

    # Presses a button where the mouse is.
    def down(button : MouseButton = MouseButton::Left, click_count : Int32 = 1, progress : Progress? = nil) : Nil
      here = position
      @mutex.synchronize { @buttons << button }
      dispatch(CDP::Protocol::Input::DispatchMouseEventRequestType::MousePressed,
        here.x, here.y, button, click_count, progress)
    end

    # Releases a button where the mouse is.
    def up(button : MouseButton = MouseButton::Left, click_count : Int32 = 1, progress : Progress? = nil) : Nil
      here = position
      @mutex.synchronize { @buttons.delete(button) }
      dispatch(CDP::Protocol::Input::DispatchMouseEventRequestType::MouseReleased,
        here.x, here.y, button, click_count, progress)
    end

    # Moves to a point and clicks there.
    #
    # The move comes first and is not decoration: a page that only reacts to
    # `mouseover` — a menu that opens on hover and closes when the pointer
    # leaves — behaves completely differently for a click that arrives without
    # the pointer ever having travelled there.
    def click(point : Point, button : MouseButton = MouseButton::Left, click_count : Int32 = 1,
              delay : Time::Span? = nil, progress : Progress? = nil) : Nil
      move(point.x, point.y, progress)
      down(button, click_count, progress)
      sleep(delay) if delay
      up(button, click_count, progress)
    end

    private def dispatch(type, x : Float64, y : Float64, button : MouseButton?,
                         click_count : Int32, progress : Progress?) : Nil
      pressed = @mutex.synchronize { @buttons.dup }
      Crystalwright.command(@session, CDP::Protocol::Input::DispatchMouseEventRequest.new(
        type: type,
        x: x,
        y: y,
        button: (button || MouseButton::Left).to_protocol,
        buttons: pressed.sum { |held| held.left? ? 1 : held.right? ? 2 : 4 },
        click_count: click_count,
      ), progress, "Input.dispatchMouseEvent")
    end
  end

  # The keyboard.
  #
  # Text goes in through `Input.insertText`, which is what a paste or an input
  # method does and is the only way to enter a character the layout cannot
  # produce with one key. Named keys go through real key events, because a page
  # listening for Enter is listening for a `keydown`, not for a character.
  class Keyboard
    # What one named key looks like on the wire.
    record Key, key : String, code : String, key_code : Int32, text : String? = nil

    # The named keys, with the codes a US layout would produce.
    #
    # A deliberate subset rather than the whole layout table: these are the keys
    # a test presses by name. Anything printable is text and goes through
    # `type`, where the layout does not come into it.
    KEYS = {
      "Enter"      => Key.new("Enter", "Enter", 13, "\r"),
      "Tab"        => Key.new("Tab", "Tab", 9, "\t"),
      "Escape"     => Key.new("Escape", "Escape", 27),
      "Backspace"  => Key.new("Backspace", "Backspace", 8),
      "Delete"     => Key.new("Delete", "Delete", 46),
      "ArrowLeft"  => Key.new("ArrowLeft", "ArrowLeft", 37),
      "ArrowUp"    => Key.new("ArrowUp", "ArrowUp", 38),
      "ArrowRight" => Key.new("ArrowRight", "ArrowRight", 39),
      "ArrowDown"  => Key.new("ArrowDown", "ArrowDown", 40),
      "Home"       => Key.new("Home", "Home", 36),
      "End"        => Key.new("End", "End", 35),
      "PageUp"     => Key.new("PageUp", "PageUp", 33),
      "PageDown"   => Key.new("PageDown", "PageDown", 34),
      "Space"      => Key.new(" ", "Space", 32, " "),
    }

    # :nodoc:
    def initialize(@session : CDP::Session)
    end

    # Types text into whatever has focus.
    def type(text : String, progress : Progress? = nil) : Nil
      return if text.empty?
      Crystalwright.command(@session, CDP::Protocol::Input::InsertTextRequest.new(text: text),
        progress, "Input.insertText")
    end

    # Presses one key and releases it.
    #
    # A named key from `KEYS`, or a single character, which is sent as text so
    # that the layout is never guessed at.
    def press(key : String, progress : Progress? = nil) : Nil
      described = KEYS[key]?
      unless described
        if key.size == 1
          type(key, progress)
          return
        end
        raise Error.new("#{key.inspect} is not a key this shard knows. \
                         Known keys: #{KEYS.keys.sort!.join(", ")}. \
                         A single character is typed as text.")
      end

      down(described, progress)
      up(described, progress)
    end

    private def down(key : Key, progress : Progress?) : Nil
      Crystalwright.command(@session, CDP::Protocol::Input::DispatchKeyEventRequest.new(
        type: key.text ? CDP::Protocol::Input::DispatchKeyEventRequestType::KeyDown : CDP::Protocol::Input::DispatchKeyEventRequestType::RawKeyDown,
        key: key.key,
        code: key.code,
        windows_virtual_key_code: key.key_code,
        native_virtual_key_code: key.key_code,
        text: key.text,
        unmodified_text: key.text,
      ), progress, "Input.dispatchKeyEvent")
    end

    private def up(key : Key, progress : Progress?) : Nil
      Crystalwright.command(@session, CDP::Protocol::Input::DispatchKeyEventRequest.new(
        type: CDP::Protocol::Input::DispatchKeyEventRequestType::KeyUp,
        key: key.key,
        code: key.code,
        windows_virtual_key_code: key.key_code,
        native_virtual_key_code: key.key_code,
      ), progress, "Input.dispatchKeyEvent")
    end
  end
end
