require 'openssl'
require 'json'
require 'base64'
require 'net/http'

# Automatic signing on a fresh runner mints a development certificate whose private key dies with the
# runner. Revoke those so the team never hits Apple's certificate limit; personal certificates are left alone.

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

def api(method, path)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  req = { get: Net::HTTP::Get, delete: Net::HTTP::Delete }.fetch(method).new(uri)
  req['Authorization'] = "Bearer #{token}"
  res = Net::HTTP.start(uri.host, 443, use_ssl: true) { |http| http.request(req) }
  abort "#{method.upcase} #{path} -> #{res.code}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)
  res.body.to_s.empty? ? {} : JSON.parse(res.body)
end

certs = api(:get, '/v1/certificates?filter[certificateType]=DEVELOPMENT,IOS_DEVELOPMENT&limit=200')['data']
stale = certs.select { |c| "#{c.dig('attributes', 'name')} #{c.dig('attributes', 'displayName')}".include?('Created via API') }
stale.each do |cert|
  api(:delete, "/v1/certificates/#{cert['id']}")
  puts "Revoked #{cert.dig('attributes', 'displayName') || cert['id']} (expires #{cert.dig('attributes', 'expirationDate')})"
end
puts "#{stale.size} CI development certificate(s) revoked, #{certs.size - stale.size} kept"
