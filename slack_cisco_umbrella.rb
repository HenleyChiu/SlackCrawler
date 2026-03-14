require 'net/http'
require 'zip'      # gem install rubyzip
require 'set'
require 'uri'
require 'date'

# ─────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────

# How many days back to download. More days = more companies discovered,
# since different companies appear on different days.
DAYS_TO_FETCH    = 7

CLOUDFLARE_LIST  = 'cloudflare_list.txt'
OUTPUT_FILE      = 'umbrella_slack_companies.txt'

TLD_PRIORITY     = %w[.com .net .org .io .ai]

# Umbrella publishes one file per day at this URL pattern
UMBRELLA_URL     = 'http://s3-us-west-1.amazonaws.com/umbrella-static/top-1m-%s.csv.zip'

# ─────────────────────────────────────────────
# STEP 1: Download and unzip each day's file
# ─────────────────────────────────────────────

def download_umbrella_file(date_str)
  url      = UMBRELLA_URL % date_str
  zip_path = "umbrella-#{date_str}.csv.zip"

  puts "  Downloading #{url}..."

  uri      = URI(url)
  response = Net::HTTP.get_response(uri)

  if response.code.to_i != 200
    puts "  [!] #{response.code} — file not available for #{date_str}, skipping."
    return nil
  end

  File.binwrite(zip_path, response.body)
  zip_path

rescue => e
  puts "  [!] Download error for #{date_str}: #{e.message}"
  nil
end

def extract_lines_from_zip(zip_path)
  lines = []
  Zip::File.open(zip_path) do |zip|
    zip.each do |entry|
      next unless entry.name.end_with?('.csv')
      entry.get_input_stream.each_line { |line| lines << line.strip }
    end
  end
  lines
rescue => e
  puts "  [!] Error reading zip #{zip_path}: #{e.message}"
  []
end

# ─────────────────────────────────────────────
# STEP 2: Load the Cloudflare domain list
# (used for matching non-Enterprise Grid entries)
# ─────────────────────────────────────────────

puts "Loading Cloudflare domain list..."
cloudflare_domains = Set.new
File.foreach(CLOUDFLARE_LIST) do |line|
  domain = line.strip.split(',').last.to_s.downcase
  cloudflare_domains.add(domain) unless domain.empty?
end
puts "Loaded #{cloudflare_domains.size} domains.\n\n"

# ─────────────────────────────────────────────
# STEP 3: Download each day's file, scan for
# slack.com entries, and extract company names
# ─────────────────────────────────────────────
#
# The Umbrella CSV format is: rank,domain
# e.g:
#   1,google.com
#   4521,slack.com
#   89302,lyft.enterprise.slack.com
#
# Two types of Slack entries:
#
#   A) Enterprise Grid subdomains:
#      companyname.enterprise.slack.com
#      -> company name is RIGHT THERE in the subdomain, no guessing needed
#
#   B) Generic slack.com / app.slack.com traffic:
#      -> no company info, skip these
#
# ─────────────────────────────────────────────

enterprise_domains = Set.new  # confirmed from Enterprise Grid subdomains
workspace_names    = Set.new  # workspace names to match against Cloudflare list

today = Date.today

(0...DAYS_TO_FETCH).each do |days_ago|
  date     = today - days_ago
  date_str = date.strftime('%Y-%m-%d')

  puts "Processing #{date_str}..."

  zip_path = download_umbrella_file(date_str)
  next unless zip_path

  lines = extract_lines_from_zip(zip_path)
  puts "  #{lines.size} total entries in file."

  slack_lines = lines.select { |l| l.include?('slack.com') }
  puts "  #{slack_lines.size} Slack-related entries found."

  slack_lines.each do |line|
    domain = line.split(',').last.to_s.strip.downcase

    if domain =~ /\A(.+)\.enterprise\.slack\.com\z/
      # Type A: Enterprise Grid — company name is the first subdomain segment
      # e.g. lyft.enterprise.slack.com -> lyft -> try lyft.com
      company_slug = $1
      # Some are nested like grid-strava.enterprise.slack.com
      # The company name is typically the last hyphen-segment or the whole slug
      workspace_names.add(company_slug)

    elsif domain =~ /\A(.+)\.slack\.com\z/
      # Type B: named workspace subdomain like stytch.slack.com
      # (less common in Umbrella data but worth catching)
      slug = $1
      next if %w[app status api files].include?(slug)
      workspace_names.add(slug)
    end
    # Plain "slack.com" entries are skipped — no company info to extract
  end

  # Clean up the zip to save disk space
  File.delete(zip_path) if File.exist?(zip_path)
  puts ""
end

# ─────────────────────────────────────────────
# STEP 4: Resolve workspace/company slugs
# to actual domains
#
# For Enterprise Grid entries, the slug IS the company name —
# but we still need to find the right TLD (.com, .io, etc.)
# That's where the Cloudflare list comes in.
#
# For slugs like "grid-strava" (Slack's internal grid ID format),
# we strip the "grid-" prefix and try again.
# ─────────────────────────────────────────────

puts "Resolving #{workspace_names.size} workspace names to domains...\n\n"

matched_domains = Set.new

workspace_names.each do |slug|
  # Some Enterprise Grid slugs use a "grid-companyname" format
  # Try both the raw slug and the de-prefixed version
  candidates = [slug, slug.sub(/\Agrid-/, '')]

  candidates.each do |name|
    matched_tld = TLD_PRIORITY.find { |tld| cloudflare_domains.include?("#{name}#{tld}") }
    if matched_tld
      domain = "#{name}#{matched_tld}"
      puts "  ✓ #{slug} => #{domain}"
      matched_domains.add(domain)
      break
    end
  end
end

# ─────────────────────────────────────────────
# STEP 5: Write results to output file
# ─────────────────────────────────────────────

all_domains = matched_domains.to_a.sort
File.write(OUTPUT_FILE, all_domains.join("\n"))

puts "\nDone! #{all_domains.size} company domains found across #{DAYS_TO_FETCH} days."
puts "Results written to #{OUTPUT_FILE}"
puts "\nTip: Increase DAYS_TO_FETCH at the top of the script to surface more companies."
