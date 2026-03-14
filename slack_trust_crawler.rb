require 'net/http'
require 'json'
require 'uri'

# ─────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────

OXYLABS_USER     = 'your_oxylabs_username'
OXYLABS_PASS     = 'your_oxylabs_password'
OXYLABS_ENDPOINT = 'https://realtime.oxylabs.io/v1/queries'

OUTPUT_FILE      = 'trust_center_slack_companies.txt'

RESULTS_PER_PAGE = 10
MAX_PAGES        = 10

# ─────────────────────────────────────────────
# STEP 1: Fetch all pages of Google results
# for trust center subdomains mentioning Slack
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
  return [] if response.code.to_i != 200

  body    = JSON.parse(response.body)
  organic = body.dig('results', 0, 'content', 'results', 'organic')
  organic ? organic.map { |r| r['url'] }.compact : []

rescue => e
  puts "  [!] Error on page #{page}: #{e.message}"
  []
end

puts "Fetching trust center pages that mention Slack...\n\n"

all_urls = []
(1..MAX_PAGES).each do |page|
  print "  Page #{page}... "
  urls = fetch_serp_page('site:trust.*.com "Slack"', page, RESULTS_PER_PAGE)
  puts "#{urls.size} results"
  all_urls.concat(urls)
  break if urls.size < RESULTS_PER_PAGE
  sleep 1
end

puts "\nTotal URLs collected: #{all_urls.size}"

# ─────────────────────────────────────────────
# STEP 2: Extract the root domain from each URL
#
# Trust center URLs look like:
#   https://trust.mixpanel.com/subprocessors
#   https://trust.ketch.com/subprocessors
#   https://trust.apptegy.com/subprocessors
#   https://trust.secondfront.com
#
# Just like the docs.*.com method, we strip the
# "trust." prefix and the root domain is what's left.
# ─────────────────────────────────────────────

puts "\nExtracting company domains..."

domains = all_urls.filter_map do |url|
  host = URI.parse(url).host rescue next
  host.sub(/\Atrust\./, '').downcase
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
