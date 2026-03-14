require 'resolv'
require 'thread'

# ─────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────

CLOUDFLARE_LIST  = 'cloudflare_list.txt'
OUTPUT_FILE      = 'google_workspace_companies.txt'

# How many domains to check concurrently.
# DNS lookups are mostly waiting, so threading speeds this up a lot.
# Keep it under 50 to avoid hammering your local DNS resolver.
THREAD_COUNT     = 20

# Google Workspace MX records all end with .google.com or .googlemail.com
GOOGLE_MX_PATTERN = /google(mail)?\.com\.?\z/i

# ─────────────────────────────────────────────
# STEP 1: Load domains from Cloudflare list
# ─────────────────────────────────────────────

puts "Loading Cloudflare domain list..."

domains = []
File.foreach(CLOUDFLARE_LIST) do |line|
  # Cloudflare Radar format: "rank,domain" e.g. "1,google.com"
  domain = line.strip.split(',').last.to_s.downcase
  domains << domain unless domain.empty?
end

puts "Loaded #{domains.size} domains to check.\n\n"

# ─────────────────────────────────────────────
# STEP 2: Check each domain's MX records
#
# Google Workspace MX records look like:
#   aspmx.l.google.com
#   alt1.aspmx.l.google.com
#   alt2.aspmx.l.google.com
#   aspmx2.googlemail.com
#
# Any MX record ending in .google.com or .googlemail.com
# confirms Google Workspace.
#
# We use threads because DNS lookups spend most of their
# time waiting for a response — running them in parallel
# cuts the total runtime dramatically.
# ─────────────────────────────────────────────

def uses_google_workspace?(domain)
  mx_records = Resolv::DNS.open do |dns|
    dns.getresources(domain, Resolv::DNS::Resource::IN::MX)
  end

  mx_records.any? { |mx| mx.exchange.to_s.match?(GOOGLE_MX_PATTERN) }

rescue Resolv::ResolvError, Resolv::ResolvTimeout
  false  # domain has no MX records or timed out — skip it
rescue => e
  false
end

puts "Checking MX records with #{THREAD_COUNT} threads...\n\n"

results   = []
results_mutex = Mutex.new
queue     = Queue.new
domains.each { |d| queue << d }

checked   = 0
counter_mutex = Mutex.new

threads = THREAD_COUNT.times.map do
  Thread.new do
    until queue.empty?
      domain = queue.pop(true) rescue nil
      next unless domain

      if uses_google_workspace?(domain)
        results_mutex.synchronize { results << domain }
        puts "  ✓ #{domain}"
      end

      counter_mutex.synchronize do
        checked += 1
        print "\r  Checked #{checked}/#{domains.size} domains..." if checked % 100 == 0
      end
    end
  end
end

threads.each(&:join)
puts "\n\nDone checking all domains."

# ─────────────────────────────────────────────
# STEP 3: Write results to output file
# ─────────────────────────────────────────────

results.sort!
File.write(OUTPUT_FILE, results.join("\n"))

puts "#{results.size} Google Workspace companies found."
puts "Results written to #{OUTPUT_FILE}"
puts "\nReminder: this is a proxy, not a confirmation."
puts "Google Workspace companies are more likely to use Slack than Teams,"
puts "but you'll want to layer in other methods to qualify the list further."
