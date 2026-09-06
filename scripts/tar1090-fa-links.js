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
})();
