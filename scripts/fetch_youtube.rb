#!/usr/bin/env ruby
# Generates one Jekyll post per video in the KG7AJM YouTube playlist.
#
# WHAT IT DOES
#   1. Fetches the playlist page and pulls the embedded ytInitialData JSON out of it:
#      every video, in playlist order, with its title and view count.
#   2. Asks each video's own page for its real upload date.
#   3. Writes _posts/<date>-<video_id>.md, newest upload first.
#
# WHY IT IS BUILT THIS WAY (each of these is a failure that actually happened)
#
#   * It never invents data it did not see. Anything fetched this run is used; anything
#     missing falls back to what the previous post for that video already recorded, and
#     only then to a computed guess. GitHub's runners are served a degraded YouTube page:
#     all 31 upload-date lookups came back empty there and several view counts read 0,
#     where the same code on a home connection gets every one. Without the reuse step that
#     degraded run would zero the view counts and move every video.
#
#   * Order is playlist position with real dates preferred, never the clock. YouTube
#     renders the playlist oldest-first, so the last entry is the newest video. The old
#     version dated posts `now` minus one hour per slot, which meant a post's date (and so
#     its url) changed on every run.
#
#   * Dates are ISO-8601 with a Z, e.g. 2026-09-03T12:00:00Z. The spaced form it used to
#     write (`2026-09-11 23:35:44 +0000`) is not accepted by every YAML parser, and when
#     Jekyll refuses a front-matter date it silently falls back to the filename date at
#     midnight. That is exactly what put the September 3rd video at position 24 instead of
#     first, with a green build and no warning.
#
#   * The filename carries the same date the front matter does, so even a rejected date
#     cannot move a post to the wrong end of the list.
#
#   * ytInitialData is extracted by scanning for the matching closing brace, NOT with
#     `grep -o 'var ytInitialData = [^;]*'`, which stops at the first semicolon inside the
#     JSON (titles contain them) and silently truncates.
#
#   * View counts and ages are pulled by regex over the whole lockup object rather than by
#     walking a fixed key path. YouTube moves those keys; when the path missed, the old
#     version wrote view_count: 0 for every video without failing.
#
#   * _posts is cleared before writing, so a post from an older run cannot survive with a
#     stale date and show the same video twice.
#
# USAGE
#   ruby scripts/fetch_youtube.rb          # run from the repo root
#   ruby scripts/fetch_youtube.rb --check  # report only, write nothing

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

# ytInitialData, found by brace matching so nothing inside the JSON can cut it short.
def extract_yt_initial_data(html)
  marker = 'var ytInitialData = '
  start = html.index(marker)
  return nil unless start
  start = html.index('{', start)
  return nil unless start
  depth = 0
  html[start..].each_char.with_index do |ch, i|
    case ch
    when '{' then depth += 1
    when '}'
      depth -= 1
      return html[start..(start + i)] if depth.zero?
    end
  end
  nil
end

# The real upload date from the video's own page, or nil. Two tries, because the first call
# to a fresh YouTube connection sometimes lands on a consent interstitial.
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

# What the previous post for a video says. This is the safety net for a degraded fetch.
previous = {}
Dir.glob(File.join(POSTS_DIR, '*.md')).each do |file|
  text = File.read(file) rescue next
  id = text[/^video_id:\s*(\S+)/, 1]
  next if id.nil?
  previous[id] = {
    date: ((Time.parse(text[/^date:\s*(\S+)/, 1]) rescue nil) if text[/^date:\s*(\S+)/, 1]),
    views: text[/^view_count:\s*(\d+)/, 1].to_i,
    file: file
  }
end
puts "Found #{previous.length} existing post(s) to compare against." unless previous.empty?

puts 'Fetching the playlist...'
html = curl("https://www.youtube.com/playlist?list=#{PLAYLIST_ID}")
if html.to_s.strip.empty?
  puts 'Error: YouTube returned nothing for the playlist.'
  exit 1
end

json_raw = extract_yt_initial_data(html)
unless json_raw
  puts 'Error: could not find ytInitialData in the playlist page.'
  exit 1
end

begin
  data = JSON.parse(json_raw)
  items = data['contents']['twoColumnBrowseResultsRenderer']['tabs'][0]['tabRenderer']['content']['sectionListRenderer']['contents'][0]['itemSectionRenderer']['contents']
  lockups = items.select { |item| item.key?('lockupViewModel') }.map { |item| item['lockupViewModel'] }
rescue StandardError => e
  puts "Error parsing JSON structure: #{e.message}"
  puts 'YouTube may have changed their page layout. The expected path was:'
  puts '  contents > twoColumnBrowseResultsRenderer > tabs[0] > tabRenderer > content > sectionListRenderer > contents[0] > itemSectionRenderer > contents'
  exit 1
end

# Playlist order. YouTube renders oldest first, so a higher position is a newer video.
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

if videos.empty?
  puts 'Error: the playlist page parsed but held no videos.'
  exit 1
end

last_position = videos.map { |v| v[:position] }.max

puts "Found #{videos.length} videos. Reading each video page for its upload date..."
videos.each_with_index do |v, i|
  # view count: what we can see now, else what the previous post recorded, else zero
  v[:views] = parse_views(v[:view_text])
  v[:views_source] = :fresh
  if v[:views].zero? && previous[v[:id]] && previous[v[:id]][:views].positive?
    v[:views] = previous[v[:id]][:views]
    v[:views_source] = :previous
  end

  # date: the real upload date, else the date this video's post already carried,
  # else an ordering slot counted back from now (last playlist entry = now)
  v[:date] = upload_date(v[:id])
  v[:date_source] = :upload
  if v[:date].nil? && previous[v[:id]] && previous[v[:id]][:date]
    v[:date] = previous[v[:id]][:date]
    v[:date_source] = :previous
  end
  if v[:date].nil?
    v[:date] = Time.now.utc - ((last_position - v[:position]) * 3600)
    v[:date_source] = :position
  end

  print "\r  read #{i + 1}/#{videos.length}" if ((i + 1) % 10).zero? || i == videos.length - 1
end
puts

# Newest first. Same day: the later playlist position wins, which is the order Jon arranges.
videos.sort_by! { |v| [-v[:date].to_i, -v[:position]] }

by_source = videos.group_by { |v| v[:date_source] }.transform_values(&:length)
puts "  dates: #{by_source.map { |k, n| "#{n} #{k}" }.join(', ')}"
puts "  views: #{videos.count { |v| v[:views_source] == :fresh }} fresh, #{videos.count { |v| v[:views_source] == :previous }} carried over"

if CHECK_ONLY
  puts
  puts 'Newest first:'
  videos.first(3).each { |v| puts "  #{v[:date].strftime('%Y-%m-%d')}  #{v[:id]}  #{v[:title][0, 50]}  (#{v[:date_source]})" }
  puts '  ...'
  last = videos.last
  puts "  #{last[:date].strftime('%Y-%m-%d')}  #{last[:id]}  #{last[:title][0, 50]}  (#{last[:date_source]})"
  exit 0
end

stale = Dir.glob(File.join(POSTS_DIR, '*.md'))
unless stale.empty?
  puts "Clearing #{stale.length} existing post(s) from #{POSTS_DIR} before regenerating..."
  File.delete(*stale)
end

videos.each_with_index do |v, index|
  # Same real day for every video uploaded that day, plus the playlist position in seconds
  # so same-day videos keep a fixed order and the value never changes between runs.
  stamp = Time.utc(v[:date].year, v[:date].month, v[:date].day, 12, 0, 0) + v[:position]

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
  File.write(File.join(POSTS_DIR, "#{stamp.strftime('%Y-%m-%d')}-#{v[:id]}.md"),
             "#{frontmatter}\n\n#{body.strip}\n")
  puts "  [#{index + 1}/#{videos.length}] #{stamp.strftime('%Y-%m-%d')}  #{v[:id]}  #{v[:title][0, 46]}"
end

puts
puts "Wrote #{videos.length} posts."
puts "  newest: #{videos.first[:date].strftime('%Y-%m-%d')}  #{videos.first[:title][0, 50]}"
puts "  oldest: #{videos.last[:date].strftime('%Y-%m-%d')}  #{videos.last[:title][0, 50]}"

zero_views = videos.select { |v| v[:views].zero? }
unless zero_views.empty?
  puts
  puts "WARNING: no view count for #{zero_views.length} video(s) (neither now nor in a previous post):"
  zero_views.each { |v| puts "  - #{v[:id]}  #{v[:title][0, 46]}" }
end

if videos.all? { |v| v[:date_source] == :position }
  puts
  puts 'NOTE: no upload dates were available this run, so every post is ordered by its'
  puts 'playlist position. The order is still newest first; only the dates are approximate.'
  puts 'That is expected on a GitHub runner, which YouTube serves a reduced page.'
end
