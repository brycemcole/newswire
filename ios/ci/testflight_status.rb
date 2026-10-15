require_relative 'asc'

number = ARGV.fetch(0)
abort 'Expected a numeric build number' unless number.match?(/\A\d+\z/)
previous = nil
60.times do
  response = api(:get, "/v1/builds?filter[app]=#{APP_ID}&filter[version]=#{number}&include=buildBetaDetail,betaGroups")
  build = response['data'].first
  included = response.fetch('included', [])
  attributes = build&.fetch('attributes', {}) || {}
  detail = included.find { |item| item['type'] == 'buildBetaDetails' }&.fetch('attributes', {}) || {}
  state = { build: number, processing: attributes['processingState'], expired: attributes['expired'],
            internal: detail['internalBuildState'], external: detail['externalBuildState'],
            groups: included.select { |item| item['type'] == 'betaGroups' }.map { |item|
              item['attributes'].slice('name', 'isInternalGroup', 'hasAccessToAllBuilds')
            } }
  state[:ready] = state[:processing] == 'VALID' && !state[:expired] && [state[:internal], state[:external]].include?('IN_BETA_TESTING')
  serialized = JSON.generate(state)
  if serialized != previous
    puts serialized
    STDOUT.flush
    previous = serialized
  end
  if state[:ready]
    if ENV['GITHUB_STEP_SUMMARY']
      File.open(ENV['GITHUB_STEP_SUMMARY'], 'a') { |file| file.puts "TestFlight build #{number}: processed and available for beta testing." }
    end
    exit 0
  end
  abort "Build #{number} failed Apple processing" if %w[FAILED INVALID].include?(state[:processing]) || state[:expired]
  sleep 15
end
abort "Build #{number} is not available for beta testing; see the processing and testing states above"
