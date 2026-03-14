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

# Optional: a GitHub personal access token for higher API rate limits.
# Without it you get 60 requests/hour. With it: 5,000/hour.
# Generate one at: github.com/settings/tokens (no scopes needed, public data only)
GITHUB_TOKEN = nil  # or 'ghp_yourtoken...'

OUTPUT_FILE      = 'github_slack_companies.txt'
RESULTS_PER_PAGE = 10
MAX_PAGES        = 10

# ─────────────────────────────────────────────
# STEP 1: Use OxyLabs to get all GitHub URLs
# that contain a join.slack.com link
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
  puts "  [!] SERP error on page #{page}: #{e.message}"
  []
end

puts "Fetching GitHub URLs that mention join.slack.com..."

all_github_urls = []
(1..MAX_PAGES).each do |page|
  print "  Page #{page}... "
  urls = fetch_serp_page('site:github.com "join.slack.com"', page, RESULTS_PER_PAGE)
  puts "#{urls.size} results"
  all_github_urls.concat(urls)
  break if urls.size < RESULTS_PER_PAGE
  sleep 1
end

puts "Total GitHub URLs collected: #{all_github_urls.size}"

# ─────────────────────────────────────────────
# STEP 2: Extract the GitHub org/user name
# from each URL
#
# GitHub URLs look like:
#   https://github.com/locustio/locust/issues/2368
#   https://github.com/kubeflow/community/issues/220
#   https://github.com/first-contributions/README.md
#
# We want the first path segment: locustio, kubeflow, first-contributions
# That's the GitHub org name, and github.com/ORG is their profile page.
# ─────────────────────────────────────────────

puts "\nExtracting GitHub org names..."

org_names = all_github_urls.filter_map do |url|
  path_parts = URI.parse(url).path.split('/').reject(&:empty?)
  # First segment is the org/user name. Skip if it's a GitHub-level page.
  next if path_parts.empty?
  org = path_parts.first.downcase
  next if %w[orgs topics explore marketplace].include?(org)
  org
rescue URI::InvalidURIError
  nil
end.uniq

puts "Unique GitHub orgs found: #{org_names.size}"

# ─────────────────────────────────────────────
# STEP 3: Look up each org on the GitHub API
# to get their website URL
#
# GitHub's public API returns a "blog" field which is
# where orgs list their website. It's free to call,
# though rate-limited (60 req/hr without a token).
#
# API endpoint: https://api.github.com/orgs/ORGNAME
# (also falls back to /users/ORGNAME for personal accounts)
# ─────────────────────────────────────────────

def fetch_github_website(org_name, token = nil)
  ['orgs', 'users'].each do |type|
    uri  = URI("https://api.github.com/#{type}/#{org_name}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Get.new(uri)
    request['User-Agent']    = 'slack-finder-script'
    request['Accept']        = 'application/vnd.github+json'
    request['Authorization'] = "Bearer #{token}" if token

    response = http.request(request)
    next unless response.code.to_i == 200

    data    = JSON.parse(response.body)
    website = data['blog'].to_s.strip
    return website unless website.empty?

    return nil  # org exists but no website listed
  end

  nil  # neither orgs nor users endpoint returned a result

rescue => e
  puts "  [!] GitHub API error for #{org_name}: #{e.message}"
  nil
end

def normalize_domain(url)
  url = url.strip
  return nil if url.empty?

  # Add scheme if missing so URI can parse it
  url = "https://#{url}" unless url.start_with?('http')

  URI.parse(url).host&.downcase&.sub(/\Awww\./, '')
rescue URI::InvalidURIError
  nil
end

puts "\nLooking up GitHub org websites..."

domains = []
org_names.each_with_index do |org, i|
  print "  [#{i + 1}/#{org_names.size}] #{org}... "

  website = fetch_github_website(org, GITHUB_TOKEN)

  if website
    domain = normalize_domain(website)
    if domain
      puts "=> #{domain}"
      domains << domain
    else
      puts "=> (unparseable: #{website})"
    end
  else
    puts "=> no website listed"
  end

  # Stay under GitHub's rate limit.
  # 60 req/hr unauthenticated = 1 request every 60 seconds to be safe.
  # With a token you get 5,000/hr, so the sleep is much shorter.
  sleep(GITHUB_TOKEN ? 0.1 : 61)
end

# ─────────────────────────────────────────────
# STEP 4: Write results to output file
# ─────────────────────────────────────────────

domains = domains.uniq.sort
File.write(OUTPUT_FILE, domains.join("\n"))

puts "\nDone! #{domains.size} company domains found."
puts "Results written to #{OUTPUT_FILE}"
