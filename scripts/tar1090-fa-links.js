// Point tar1090's callsign links at FlightAware's live flight page.
//
// tar1090 builds the Callsign column and the selected-aircraft panel with
// getFlightAwareModeSLink(icao, ident, linkText), which links to
//   https://flightaware.com/live/modes/<icao>/ident/<ident>/redirect
// We want the flight page directly:
//   https://flightaware.com/live/flight/<CALLSIGN>
//
// script.js declares that helper as a top-level function, so it lands on
// window and can be replaced once script.js has loaded. This file is injected
// last, after script.js, so the override wins without patching upstream.

(function () {
  "use strict";

  var upstreamModeSLink = window.getFlightAwareModeSLink;

  function escapeHtml(text) {
    return String(text)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  // FlightAware wants the callsign uppercase with no spaces or punctuation,
  // e.g. "ANZ 146 " -> "ANZ146".
  function normaliseCallsign(ident) {
    return String(ident || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
  }

  window.getFlightAwareModeSLink = function (code, ident, linkText) {
    var callsign = normaliseCallsign(ident);
    if (callsign) {
      var text = escapeHtml(linkText || String(ident).trim());
      return '<a class="link" target="_blank" rel="noreferrer" ' +
             'href="https://flightaware.com/live/flight/' + callsign + '">' +
             text + "</a>";
    }
    // No callsign (military, blocked, or not yet received) - fall back to
    // upstream's Mode-S lookup by ICAO hex, which still resolves.
    return upstreamModeSLink ? upstreamModeSLink(code, ident, linkText) : "";
  };

  // The selected-aircraft panel is a separate problem: script.js writes a
  // FlightAware link into #selected_flightaware_link, but this build of
  // tar1090 has no such element in index.html, so that write goes nowhere.
  // Linkify #selected_callsign directly instead.
  //
  // Safe against tar1090's own updates: updateText() is
  //   this.text() !== String(text) && this.text(text)
  // and an <a> still reports the callsign as its text, so tar1090 leaves our
  // link alone until the selected aircraft actually changes. When it does, it
  // replaces our anchor with a text node and the observer re-links it.
  function linkifySelectedCallsign() {
    var el = document.getElementById("selected_callsign");
    if (!el) return;

    var text = (el.textContent || "").trim();
    var callsign = normaliseCallsign(text);
    if (!callsign || text === "n/a") return;

    var existing = el.querySelector("a[data-fa-callsign]");
    if (existing && existing.getAttribute("data-fa-callsign") === callsign) {
      return; // already correct - stops the observer looping
    }

    el.innerHTML = '<a class="link" target="_blank" rel="noreferrer" ' +
      'data-fa-callsign="' + callsign + '" ' +
      'href="https://flightaware.com/live/flight/' + callsign + '">' +
      escapeHtml(text) + "</a>";
  }

  function watchSelectedCallsign() {
    var el = document.getElementById("selected_callsign");
    if (!el) return;
    if (window.MutationObserver) {
      new window.MutationObserver(linkifySelectedCallsign).observe(el, {
        childList: true,
        characterData: true,
        subtree: true,
      });
    }
    linkifySelectedCallsign();
  }

  // Exposed so the behaviour can be exercised without a browser.
  window.tar1090FaLinks = {
    normaliseCallsign: normaliseCallsign,
    linkifySelectedCallsign: linkifySelectedCallsign,
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", watchSelectedCallsign);
  } else {
    watchSelectedCallsign();
  }
})();
