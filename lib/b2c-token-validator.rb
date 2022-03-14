# frozen_string_literal: true

require_relative "b2c-token-validator/version"

require "net/http"
require "json/jwt"

module B2CToken
  class BadIdTokenFormat < StandardError; end

  class BadIdTokenHeaderFormat < StandardError; end

  class BadIdTokenPayloadFormat < StandardError; end

  class UnableToFetchMsConfig < StandardError; end

  class UnableToFetchMsCerts < StandardError; end

  class BadPublicKeysFormat < StandardError; end

  class UnableToFindMsCertsUri < StandardError; end

  class InvalidAudience < StandardError; end

  class InvalidIssuer < StandardError; end

  class IdTokenExpired < StandardError; end

  class IdTokenNotYetValid < StandardError; end

  class Validator
    CACHED_CERTS_EXPIRY = 3600
    TOKEN_TYPE = "JWT".freeze
    TOKEN_ALGORITHM = "RS256".freeze

    def initialize(tenant_name, tenant_id, app_registration_id, policy_name, options = {})
      @cached_certs_expiry = options.fetch(:expiry, CACHED_CERTS_EXPIRY)

      @tenant_name = tenant_name
      @tenant_id = tenant_id
      @app_registration_id = app_registration_id
      @policy_name = policy_name

      # See https://docs.microsoft.com/en-us/azure/active-directory-b2c/tokens-overview for documentation
      @config_uri = "https://#{tenant_name}.b2clogin.com/#{tenant_name}.onmicrosoft.com/#{policy_name}/v2.0/.well-known/openid-configuration"
    end

    # Check the ID token and return the decoded payload
    # Raises an error if the token is invalid
    def check(id_token)
      encoded_header, encoded_payload, signature = id_token.split(".")

      raise BadIdTokenFormat if encoded_payload.nil? || signature.nil?

      header = JSON.parse(Base64.decode64(encoded_header), symbolize_names: true)
      verify_header(header)

      public_keys = JSON::JWK::Set.new(ms_public_keys)
      payload = JSON::JWT.decode(id_token, public_keys).symbolize_keys
      verify_payload(payload)

      payload
    end

    private

    def verify_header(header)
      valid_header = header[:typ] == TOKEN_TYPE && header[:alg] == TOKEN_ALGORITHM

      valid_header &= !(header[:kid].nil? && header[:x5t].nil?)

      raise BadIdTokenHeaderFormat unless valid_header
    end

    def verify_payload(payload)
      # Basic format check
      if payload[:aud].nil? ||
         payload[:exp].nil? ||
         payload[:nbf].nil? ||
         payload[:sub].nil? ||
         payload[:iss].nil? ||
         payload[:iat].nil? ||
         (iss_match = payload[:iss].match(%r{https://(.+)\.b2clogin\.com/(.+)/v2\.0})).nil?
        raise BadIdTokenPayloadFormat
      end

      # Verify audience
      raise InvalidAudience if payload[:aud] != @app_registration_id

      # Verify not before and expiration time
      current_time = Time.current.to_i
      raise IdTokenExpired if payload[:exp] < current_time
      raise IdTokenNotYetValid if payload[:nbf] > current_time

      # Verify issuer
      raise InvalidIssuer if iss_match[1].downcase != @tenant_name.downcase || iss_match[2] != @tenant_id
    end

    def ms_public_keys
      if @ms_public_keys.nil? || cached_certs_expired?
        @ms_public_keys = fetch_public_keys
        @last_cached_at = Time.current.to_i
      end

      @ms_public_keys
    end

    def fetch_public_keys
      ms_certs_uri = fetch_ms_config[:jwks_uri]

      raise UnableToFindMsCertsUri if ms_certs_uri.nil?

      uri = URI(ms_certs_uri)
      response = Net::HTTP.get_response(uri)

      raise UnableToFetchMsConfig unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body, symbolize_names: true)
    end

    def fetch_ms_config
      uri = URI(@config_uri)
      response = Net::HTTP.get_response(uri)

      raise UnableToFetchMsConfig unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body, symbolize_names: true)
    end

    def cached_certs_expired?
      !(@last_cached_at.is_a?(Integer) && @last_cached_at + @cached_certs_expiry >= Time.current.to_i)
    end
  end
end
