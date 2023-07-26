# frozen_string_literal: true

require "rack/version"

module ActionDispatch
  module Constants
    # Response Header keys for Rack 2.x and 3.x
    if Gem::Version.new(Rack::RELEASE) < Gem::Version.new("3")
      VARY = "Vary"
      CONTENT_ENCODING = "Content-Encoding"
      CONTENT_SECURITY_POLICY = "Content-Security-Policy"
      CONTENT_SECURITY_POLICY_REPORT_ONLY = "Content-Security-Policy-Report-Only"
      LOCATION = "Location"
      FEATURE_POLICY = "Feature-Policy"
      X_REQUEST_ID = "X-Request-Id"
    else
      VARY = "vary"
      CONTENT_ENCODING = "content-encoding"
      CONTENT_SECURITY_POLICY = "content-security-policy"
      CONTENT_SECURITY_POLICY_REPORT_ONLY = "content-security-policy-report-only"
      LOCATION = "location"
      FEATURE_POLICY = "feature-policy"
      X_REQUEST_ID = "x-request-id"
    end
  end
end
