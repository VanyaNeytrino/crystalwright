module Crystalwright
  # How far into loading a document a caller wants to wait.
  #
  # The order is the order they happen in, and `<=` on the enum is meaningful:
  # anything that has reached `Load` has reached `DOMContentLoaded` too.
  enum LoadState
    # The document exists and is the frame's current one. The earliest point at
    # which anything can be evaluated in it.
    Commit

    # The document has been parsed. Sub-resources may still be arriving.
    DOMContentLoaded

    # The `load` event fired: images, stylesheets and scripts are in.
    Load

    # Nothing has been requested for `NETWORK_IDLE_WINDOW`.
    #
    # Ours, not Chrome's. Chrome sends a `networkIdle` lifecycle event of its
    # own and it means something else — measured at roughly one to one and a
    # half seconds after the last request finished, varying between runs on the
    # same page. A caller who asks to wait for quiet gets 500 ms of quiet.
    NetworkIdle

    # The `LoadState` a `Page.lifecycleEvent` name stands for, if any.
    #
    # Chrome sends `init`, the paint milestones, `networkAlmostIdle` and its own
    # `networkIdle` down the same channel. None of them is a state a caller can
    # wait for here, and `networkIdle` in particular is deliberately not mapped:
    # the name matches and the meaning does not.
    def self.from_protocol(name : String) : LoadState?
      case name
      when "DOMContentLoaded" then DOMContentLoaded
      when "load"             then Load
      end
    end
  end

  # How long the network has to stay quiet before `LoadState::NetworkIdle`.
  #
  # Playwright's number, kept rather than improvised. A constant like this one
  # is the residue of a bug report somebody else already paid for, and a fresh
  # guess would have to earn its way back to the same place.
  NETWORK_IDLE_WINDOW = 500.milliseconds
end
