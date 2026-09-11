#!/usr/bin/env ruby
# Generates one Jekyll post per video in the KG7AJM YouTube playlist.
#
# HOW IT WORKS
#   1. Fetches the playlist page and pulls the embedded ytInitialData JSON out of it,
#      giving every video in playlist order with its title and view count.
#   2. Fetches each video's own page for its REAL upload date.
#   3. Writes _posts/<upload-date>-<video_id>.md, newest upload first.
#
# WHY IT LOOKS THE WAY IT DOES (each of these was a real failure)
#   * Dates are the true upload dates, taken from each video's page, NOT positions in the
#     playlist and NOT `now` minus an offset. The old version synthesised a timestamp per
#     playlist position, so the blog's order depended on YouTube rendering the playlist in
#     the order the script assumed. It did not: one post ended up dated midnight (Jekyll's
#     fallback for a front-matter date it would not accept) and sat at position 24 instead
#     of the top. The upload date is the same fact on every fetch.
#   * The front-matter date is written as ISO-8601 with a Z, e.g. 2026-09-03T12:00:00Z.
#     That is unambiguous to every YAML parser; the old spaced form (`2026-09-11 23:35:44
#     +0000`) is not, and a rejected date silently becomes the filename date at midnight.
#   * The filename carries the same real date, so even a rejected front-matter date can no
#     longer scramble the order.
#   * ytInitialData is extracted by scanning for the matching closing brace, NOT with
#     `grep -o 'var ytInitialData = [^;]*'`, which stops at the first semicolon inside the
#     JSON (titles contain them) and silently truncates.
#   * View counts and ages are pulled by regex over the whole lockup object rather than by
#     walking a fixed key path. YouTube moves those keys; when the path missed, the old
#     version wrote view_count: 0 for every video without failing.
#   * _posts is cleared before generating, so posts from a previous run cannot survive with
#     old dates and duplicate a video on the blog.
#
# USAGE
#   ruby scripts/fetch_youtube.rb          # run from the repo root
#   ruby scripts/fetch_youtube.rb --check  # fetch and report, write nothing

require 'json'
require 'fileutils'
require 'time'

PLAYLIST_ID = 'PLZyhFpAO7USvkcoWsNOFoJCeNnv1kXm-l'
POSTS_DIR = '_posts'
CHECK_ONLY = ARGV.include?('--check')

FileUtils.mkdir_p(POSTS_DIR)

def parse_views(text)
  return 0 if text.nil? || text.empty?
  return 0 if text.match?(/no views/i)
  match = text.match(/([\d.,]+)\s*([KM]?)\s+views?/i)
  return 0 unless match
  num = match[1].delete(',').to_f
  multiplier = case match[2].upcase
               when 'K' then 1000
               when 'M' then 1_000_000
               else 1
               end
  (num * multiplier).to_i
end

def curl(url)
  `curl -s -m 30 "#{url}"`
end

# Pull the ytInitialData object out of a page by scanning braces, so nothing inside the
# JSON can cut the extraction short.
def extract_yt_initial_data(html)
  marker = 'var ytInitialData = '
  start = html.index(marker)
  return nil unless start
  start = html.index('{', start)
  return nil unless start
  depth = 0
  i = start
  while i < html.length
    case html[i]
    when '{' then depth += 1
    when '}'
      depth -= 1
      return html[start..i] if depth.zero?
    end
    i += 1
  end
  nil
end

# The real upload date, straight from the video page. Returns a Time or nil.
def upload_date(video_id)
  2.times do |attempt|
    html = curl("https://www.youtube.com/watch?v=#{video_id}")
    if (m = html.match(/"uploadDate":"(\d{4})-(\d{2})-(\d{2})/))
      return Time.utc(m[1].to_i, m[2].to_i, m[3].to_i, 12, 0, 0)
    end
    sleep 1 if attempt.zero?
  end
  nil
end

puts 'Fetching the playlist...'
html = curl("https://www.youtube.com/playlist?list=#{PLAYLIST_ID}")
exit_with_message = lambda do |msg|
  puts msg
  exit 1
end
exit_with_message.call('Error: YouTube returned nothing for the playlist.') if html.to_s.strip.empty?

json_raw = extract_yt_initial_data(html)
exit_with_message.call('Error: could not find ytInitialData in the playlist page.') unless json_raw

begin
  data = JSON.parse(json_raw)
  items = data['contents']['twoColumnBrowseResultsRenderer']['tabs'][0]['tabRenderer']['content']['sectionListRenderer']['contents'][0]['itemSectionRenderer']['contents']
  lockups = items.select { |item| item.key?('lockupViewModel') }.map { |item| item['lockupViewModel'] }
rescue StandardError => e
  puts "Error parsing JSON structure: #{e.message}"
  puts 'YouTube may have changed their page layout again. The expected path was:'
  puts '  contents > twoColumnBrowseResultsRenderer > tabs[0] > tabRenderer > content > sectionListRenderer > contents[0] > itemSectionRenderer > contents'
  exit 1
end

# Playlist order, oldest first as YouTube renders it. Kept as a tiebreaker for two videos
# uploaded the same day, and as the fallback date source.
videos = []
lockups.each_with_index do |v, position|
  raw = v.to_json
  video_id = v.dig('rendererContext', 'commandContext', 'onTap', 'innertubeCommand', 'watchEndpoint', 'videoId')
  if video_id.nil?
    content_id = v['contentId'].to_s
    video_id = content_id.delete_prefix('video-') if content_id.start_with?('video-')
  end
  next unless video_id && video_id.length == 11

  videos << {
    id: video_id,
    title: v.dig('metadata', 'lockupMetadataViewModel', 'title', 'content') || 'Untitled',
    view_text: raw[/([\d.,]+[KM]?\s+views?)/i, 1] || raw[/No views/i] || '',
    age_text: raw[/(\d+\s+(?:second|minute|hour|day|week|month|year)s?\s+ago)/i, 1] || '',
    position: position
  }
end

puts "Found #{videos.length} videos in the playlist. Asking each for its upload date..."

missing_views = []
missing_dates = []
videos.each_with_index do |v, i|
  v[:views] = parse_views(v[:view_text])
  missing_views << "#{v[:id]} (#{v[:title][0, 40]})" if v[:views].zero? && v[:view_text].empty?

  v[:date] = upload_date(v[:id])
  if v[:date].nil?
    # Fall back to an ordering slot so a single unreachable page cannot fail the build,
    # but say so loudly: these posts will only be in the right place if the playlist
    # happens to be in upload order.
    v[:date] = Time.utc(2000, 1, 1) + (videos.length - v[:position]) * 86_400
    missing_dates << "#{v[:id]} (#{v[:title][0, 40]})"
  end
  print "\r  dates fetched: #{i + 1}/#{videos.length}"
end
puts

# Newest upload first. Same day: the later playlist position wins, which is how Jon
# arranges the playlist.
videos.sort_by! { |v| [-v[:date].to_i, -v[:position]] }

if CHECK_ONLY
  puts
  puts 'Newest first:'
  videos.first(3).each { |v| puts "  #{v[:date].strftime('%Y-%m-%d')}  #{v[:id]}  #{v[:title][0, 50]}" }
  puts '  ...'
  puts "  #{videos.last[:date].strftime('%Y-%m-%d')}  #{videos.last[:id]}  #{videos.last[:title][0, 50]}"
  exit 0
end

stale = Dir.glob(File.join(POSTS_DIR, '*.md'))
unless stale.empty?
  puts "Clearing #{stale.length} existing post(s) from #{POSTS_DIR} before regenerating..."
  File.delete(*stale)
end

videos.each_with_index do |v, index|
  # Same real day for every video that day; the seconds keep the intended order stable and
  # are invisible (nothing renders the time).
  stamp = v[:date] + (videos.length - index)
  frontmatter = <<~FRONTMATTER
    ---
    layout: post
    title: "#{v[:title].gsub('"', '\\"')}"
    date: #{stamp.strftime('%Y-%m-%dT%H:%M:%SZ')}
    video_id: #{v[:id]}
    view_count: #{v[:views]}
    youtube_url: https://www.youtube.com/watch?v=#{v[:id]}
    image: https://img.youtube.com/vi/#{v[:id]}/mqdefault.jpg
    ---
  FRONTMATTER

  body = v[:age_text].empty? ? v[:view_text] : "#{v[:view_text]} \u2022 #{v[:age_text]}"
  File.write(File.join(POSTS_DIR, "#{v[:date].strftime('%Y-%m-%d')}-#{v[:id]}.md"),
             "#{frontmatter}\n\n#{body.strip}\n")
  puts "  [#{index + 1}/#{videos.length}] #{v[:date].strftime('%Y-%m-%d')}  #{v[:id]}  #{v[:title][0, 46]}"
end

puts
puts "Wrote #{videos.length} posts."
puts "  newest: #{videos.first[:date].strftime('%Y-%m-%d')}  #{videos.first[:title][0, 50]}"
puts "  oldest: #{videos.last[:date].strftime('%Y-%m-%d')}  #{videos.last[:title][0, 50]}"

unless missing_dates.empty?
  puts
  puts "WARNING: #{missing_dates.length} video page(s) gave no upload date, falling back to a"
  puts 'playlist-position guess for these:'
  missing_dates.each { |m| puts "  - #{m}" }
end

unless missing_views.empty?
  puts
  puts "WARNING: no view count found for #{missing_views.length} video(s):"
  missing_views.each { |m| puts "  - #{m}" }
  if missing_views.length == videos.length
    puts
    puts 'Every video came back without a view count. That means YouTube changed the page'
    puts 'again, NOT that the videos have no views. Refusing to overwrite good data with zeros.'
    exit 1
  end
end
