require 'openssl'
require 'json'
require 'base64'
require 'net/http'

APP_ID = '6817506877'
build_number, notes_path = ARGV
notes = File.read(notes_path).strip[0, 4000]

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
  res = Net::HTTP.start(uri.host, 443, use_ssl: true) { |http| http.request(req) }
  abort "#{method.upcase} #{path} -> #{res.code}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)
end

build_id = nil
40.times do
  build_id = api(:get, "/v1/builds?filter[app]=#{APP_ID}&filter[version]=#{build_number}")['data'].first&.dig('id')
  break if build_id
  sleep 30
end
abort "Build #{build_number} never appeared in App Store Connect" unless build_id

existing = api(:get, "/v1/builds/#{build_id}/betaBuildLocalizations")['data'].find { |l| l['attributes']['locale'] == 'en-US' }
if existing
  api(:patch, "/v1/betaBuildLocalizations/#{existing['id']}",
      { data: { type: 'betaBuildLocalizations', id: existing['id'], attributes: { whatsNew: notes } } })
else
  api(:post, '/v1/betaBuildLocalizations',
      { data: { type: 'betaBuildLocalizations', attributes: { locale: 'en-US', whatsNew: notes },
                relationships: { build: { data: { type: 'builds', id: build_id } } } } })
end
puts "Set What to Test for build #{build_number}"
