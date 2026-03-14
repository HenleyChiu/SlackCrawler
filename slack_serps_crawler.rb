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

CLOUDFLARE_LIST  = 'cloudflare_list.txt'
OUTPUT_FILE      = 'slack_companies.txt'

RESULTS_PER_PAGE = 10
MAX_PAGES        = 10   # Google typically returns up to 100 results (10 pages x 10)
TLD_PRIORITY     = %w[.com .net .org .io .ai]

# ─────────────────────────────────────────────
# STEP 1: Load Cloudflare domain list into a Set
# for O(1) lookups instead of scanning line by line
# ─────────────────────────────────────────────

puts "Loading Cloudflare domain list..."

cloudflare_domains = Set.new
File.foreach(CLOUDFLARE_LIST) do |line|
  # Cloudflare Radar format is "rank,domain" e.g. "1,google.com"
  # Strip the rank prefix if present, otherwise just use the line as-is
  domain = line.strip.split(',').last.to_s.downcase
  cloudflare_domains.add(domain) unless domain.empty?
end

puts "Loaded #{cloudflare_domains.size} domains from Cloudflare list."

# ─────────────────────────────────────────────
# STEP 2: Fetch all pages of Google results
# for site:slack.com/join via OxyLabs
# ─────────────────────────────────────────────

def fetch_serp_page(page, results_per_page)
  uri  = URI(OXYLABS_ENDPOINT)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
  request.basic_auth(OXYLABS_USER, OXYLABS_PASS)
  request.body = {
    source:     'google_search',
    domain:     'com',
    query:      'site:slack.com/join',
    parse:      true,
    start_page: page,
    limit:      results_per_page,
    geo_location: 'United States'
  }.to_json

  response = http.request(request)

  if response.code.to_i != 200
    puts "  [!] HTTP #{response.code} on page #{page}, skipping."
    return []
  end

  body = JSON.parse(response.body)
  organic = body.dig('results', 0, 'content', 'results', 'organic')
  organic ? organic.map { |r| r['url'] }.compact : []

rescue => e
  puts "  [!] Error fetching page #{page}: #{e.message}"
  []
end

puts "\nFetching Slack join URLs from Google (up to #{MAX_PAGES} pages)..."

all_urls = []
(1..MAX_PAGES).each do |page|
  print "  Page #{page}... "
  urls = fetch_serp_page(page, RESULTS_PER_PAGE)
  puts "#{urls.size} results"
  all_urls.concat(urls)
  break if urls.size < RESULTS_PER_PAGE  # fewer results than expected = last page
  sleep 1  # be polite to the API
end

puts "Total Slack join URLs collected: #{all_urls.size}"

# ─────────────────────────────────────────────
# STEP 3: Extract workspace names using regex
#
# Slack join URLs look like:
#   https://stytch.slack.com/join/shared_invite/...
#   https://app.slack.com/join/...  <- no workspace name, skip these
# ─────────────────────────────────────────────

puts "\nExtracting workspace names from URLs..."

workspace_names = all_urls.filter_map do |url|
  # Match the subdomain before .slack.com, but only if it's not "app" or "join"
  match = url.match(%r{https?://([^.]+)\.slack\.com/join})
  next if match.nil?

  name = match[1].downcase
  next if %w[app www].include?(name)  # skip generic Slack subdomains

  name
end.uniq

puts "Unique workspace names found: #{workspace_names.size}"

# ─────────────────────────────────────────────
# STEP 4: Match each workspace name against
# the Cloudflare domain list, trying TLDs
# in priority order (.com first, then .net, etc.)
# ─────────────────────────────────────────────

puts "\nMatching workspace names to domains..."

matched_domains = []

workspace_names.each do |name|
  matched_tld = TLD_PRIORITY.find { |tld| cloudflare_domains.include?("#{name}#{tld}") }

  if matched_tld
    domain = "#{name}#{matched_tld}"
    matched_domains << domain
    puts "  ✓ #{name} => #{domain}"
  else
    puts "  ✗ #{name} => no match"
  end
end

# ─────────────────────────────────────────────
# STEP 5: Write results to output file
# ─────────────────────────────────────────────

matched_domains.uniq!
File.write(OUTPUT_FILE, matched_domains.join("\n"))

puts "\nDone! #{matched_domains.size} companies matched."
puts "Results written to #{OUTPUT_FILE}"
