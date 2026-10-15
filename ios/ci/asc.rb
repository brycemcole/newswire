require 'openssl'
require 'json'
require 'base64'
require 'net/http'

APP_ID = '6817506877'

def token
  key = OpenSSL::PKey::EC.new(File.read(ENV.fetch('ASC_KEY_PATH')))
  b64 = ->(s) { Base64.urlsafe_encode64(s).delete('=') }
  now = Time.now.to_i
  header = b64[{ alg: 'ES256', kid: ENV.fetch('ASC_KEY_ID'), typ: 'JWT' }.to_json]
  payload = b64[{ iss: ENV.fetch('ASC_ISSUER_ID'), iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' }.to_json]
  der = OpenSSL::ASN1.decode(key.sign(OpenSSL::Digest::SHA256.new, "#{header}.#{payload}"))
  sig = der.value.map { |i| i.value.to_s(2).rjust(32, "\0") }.join
  "#{header}.#{payload}.#{b64[sig]}"
end

def api(method, path, body = nil)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  req = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method).new(uri)
  req['Authorization'] = "Bearer #{token}"
  req['Content-Type'] = 'application/json'
  req.body = body.to_json if body
  res = Net::HTTP.start(uri.host, 443, use_ssl: true, open_timeout: 15, read_timeout: 30) { |http| http.request(req) }
  abort "#{method.upcase} #{path} -> #{res.code}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)
end
