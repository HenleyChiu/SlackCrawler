require 'net/http'
require 'json'
require 'uri'
require 'set'

# ─────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────

OXYLABS_USER     = 'your_oxylabs_username'
OXYLABS_PASS     = 'your_oxylabs_password'
OXYLABS_ENDPOINT = 'https://realtime.oxylabs.io/v1/queries'

OUTPUT_FILE      = 'slack_integration_companies.txt'

RESULTS_PER_PAGE = 10
MAX_PAGES        = 10

# Add or remove queries here. Each one surfaces a slightly different
# type of Slack user. The base query alone is plenty to start with.
QUERIES = [
  'docs.*.com "Slack integration"',
  # 'docs.*.com "Slack integration" "webhook"',
  # 'docs.*.com "Slack integration" "alert"',
  # 'docs.*.com "Slack integration" "notification"',
]

# ─────────────────────────────────────────────
# STEP 1: Fetch all pages of Google results
# for each query via OxyLabs
# ─────────────────────────────────────────────

def fetch_serp_page(query, page, results_per_page)
  uri  = URI(OXYLABS_ENDPOINT)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
  request.basic_auth(OXYLABS_USER, OXYLABS_PASS)
  request.body = {
    source:       'google_search',
    domain:       'com',
    query:        query,
    parse:        true,
    start_page:   page,
    limit:        results_per_page,
    geo_location: 'United States'
  }.to_json

  response = http.request(request)

  if response.code.to_i != 200
    puts "  [!] HTTP #{response.code} on page #{page}, skipping."
    return []
  end

  body    = JSON.parse(response.body)
  organic = body.dig('results', 0, 'content', 'results', 'organic')
  organic ? organic.map { |r| r['url'] }.compact : []

rescue => e
  puts "  [!] Error fetching page #{page}: #{e.message}"
  []
end

all_urls = []

QUERIES.each do |query|
  puts "\nSearching: #{query}"

  (1..MAX_PAGES).each do |page|
    print "  Page #{page}... "
    urls = fetch_serp_page(query, page, RESULTS_PER_PAGE)
    puts "#{urls.size} results"
    all_urls.concat(urls)
    break if urls.size < RESULTS_PER_PAGE
    sleep 1
  end
end

puts "\nTotal URLs collected: #{all_urls.size}"

# ─────────────────────────────────────────────
# STEP 2: Extract the root domain from each URL
#
# These URLs look like:
#   https://docs.mixpanel.com/docs/features/slack-integration
#   https://docs.datadoghq.com/api/latest/slack-integration
#
# We want to extract: mixpanel.com, datadoghq.com
#
# The approach: strip the "docs." subdomain and take everything
# up to and including the TLD. Works for .com, .io, .ai, etc.
# ─────────────────────────────────────────────

puts "\nExtracting company domains from URLs..."

domains = all_urls.filter_map do |url|
  host = URI.parse(url).host rescue next

  # Remove the leading "docs." subdomain to get the root domain
  # e.g. docs.mixpanel.com -> mixpanel.com
  host.sub(/\Adocs\./, '').downcase

rescue URI::InvalidURIError
  nil
end.uniq.sort

puts "Unique domains found: #{domains.size}"
domains.each { |d| puts "  #{d}" }

# ─────────────────────────────────────────────
# STEP 3: Write results to output file
# ─────────────────────────────────────────────

File.write(OUTPUT_FILE, domains.join("\n"))
puts "\nDone! Results written to #{OUTPUT_FILE}"
