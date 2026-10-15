require_relative 'asc'

build_number, notes_path = ARGV
notes = File.read(notes_path).strip[0, 4000]

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
