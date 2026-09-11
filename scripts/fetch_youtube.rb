#!/usr/bin/env ruby
# Generates one Jekyll post per video in the KG7AJM YouTube playlist.
#
# HOW IT WORKS
#   Fetches the playlist page, pulls the embedded ytInitialData JSON out of it, and
#   writes _posts/<date>-<video_id>.md for every video, newest first.
#
# WHY IT LOOKS THE WAY IT DOES (learned the hard way, 2026-09-11)
#   * ytInitialData is extracted by scanning for the matching closing brace, NOT with
#     `grep -o 'var ytInitialData = [^;]*'`. That grep stops at the first semicolon
#     inside the JSON (titles and descriptions contain them) and silently truncates.
#   * View counts and ages are pulled with regexes over the whole lockup object rather
#     than by walking a fixed key path. YouTube moves those keys around; when the path
#     missed, the old version wrote view_count: 0 for every video without failing, which
#     quietly wiped the numbers off the blog. Now a miss is reported, and a total miss
#     aborts instead of publishing zeros.
#   * _posts is cleared before generating. The old version only ever wrote files, so
#     posts from previous runs survived with their old dates and the same video showed
#     up on the blog twice.
#
# USAGE
#   ruby scripts/fetch_youtube.rb      # run from the repo root
#   ruby scripts/fetch_youtube.rb --check   # fetch and report, write nothing

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
  # "1.2K views", "12K views", "1,234 views", "1 view"
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

# Pull the ytInitialData object out of the page by scanning braces, so nothing inside
# the JSON can cut the extraction short.
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

puts 'Fetching playlist data from YouTube...'
html = `curl -s "https://www.youtube.com/playlist?list=#{PLAYLIST_ID}"`
if html.to_s.strip.empty?
  puts 'Error: YouTube returned nothing.'
  exit 1
end

json_raw = extract_yt_initial_data(html)
unless json_raw
  puts 'Error: could not find ytInitialData in the playlist page.'
  exit 1
end

data = JSON.parse(json_raw)

begin
  items = data['contents']['twoColumnBrowseResultsRenderer']['tabs'][0]['tabRenderer']['content']['sectionListRenderer']['contents'][0]['itemSectionRenderer']['contents']
  videos = items.select { |item| item.key?('lockupViewModel') }.map { |item| item['lockupViewModel'] }
  # YouTube renders the playlist oldest first; reverse so index 0 is the newest.
  videos.reverse!
rescue StandardError => e
  puts "Error parsing JSON structure: #{e.message}"
  puts 'YouTube may have changed their page layout again. The expected path was:'
  puts '  contents > twoColumnBrowseResultsRenderer > tabs[0] > tabRenderer > content > sectionListRenderer > contents[0] > itemSectionRenderer > contents'
  exit 1
end

puts "Found #{videos.length} videos in the playlist data."
exit 0 if CHECK_ONLY

stale = Dir.glob(File.join(POSTS_DIR, '*.md'))
unless stale.empty?
  puts "Clearing #{stale.length} existing post(s) from #{POSTS_DIR} before regenerating..."
  File.delete(*stale)
end

missing_views = []
generated = 0

videos.each_with_index do |v, index|
  begin
    raw = v.to_json

    video_id = v.dig('rendererContext', 'commandContext', 'onTap', 'innertubeCommand', 'watchEndpoint', 'videoId')
    if video_id.nil?
      content_id = v['contentId'].to_s
      video_id = content_id.delete_prefix('video-') if content_id.start_with?('video-')
    end
    next unless video_id && video_id.length == 11

    title = v.dig('metadata', 'lockupMetadataViewModel', 'title', 'content') || 'Untitled'

    # Structure independent: YouTube keeps these strings stable, the paths around them
    # not so much.
    view_text = raw[/([\d.,]+[KM]?\s+views?)/i, 1] || raw[/No views/i] || ''
    age_text  = raw[/(\d+\s+(?:second|minute|hour|day|week|month|year)s?\s+ago)/i, 1] || ''

    view_count = parse_views(view_text)
    missing_views << "#{video_id} (#{title[0, 40]})" if view_count.zero? && view_text.empty?

    body_line = age_text.empty? ? view_text : "#{view_text} \u2022 #{age_text}"
    body_line = body_line.strip.gsub(/\s+\z/, '')

    # Dates exist to carry playlist order into Jekyll's newest-first sort. UTC so the
    # timestamp in the front matter matches the +0000 it claims.
    date = Time.now.utc - (index * 3600)

    frontmatter = <<~FRONTMATTER
      ---
      layout: post
      title: "#{title.gsub('"', '\\"')}"
      date: #{date.strftime('%Y-%m-%d %H:%M:%S +0000')}
      video_id: #{video_id}
      view_count: #{view_count}
      youtube_url: https://www.youtube.com/watch?v=#{video_id}
      image: https://img.youtube.com/vi/#{video_id}/mqdefault.jpg
      ---
    FRONTMATTER

    File.write(File.join(POSTS_DIR, "#{date.strftime('%Y-%m-%d')}-#{video_id}.md"),
               "#{frontmatter}\n\n#{body_line}\n")
    generated += 1
    puts "Generated post [#{index + 1}/#{videos.length}]: #{video_id} (#{view_text.empty? ? 'views unknown' : view_text})"
  rescue StandardError => e
    puts "Warning: skipping video ##{index + 1}: #{e.message}"
  end
end

puts "Finished generating #{generated} posts."

unless missing_views.empty?
  puts
  puts "WARNING: no view count found for #{missing_views.length} video(s):"
  missing_views.each { |m| puts "  - #{m}" }
  if missing_views.length == generated
    puts
    puts 'Every video came back without a view count. That means YouTube changed the page'
    puts 'again, NOT that the videos have no views. Refusing to write zeros over good data.'
    puts 'Re-run with --check to inspect without touching _posts.'
    exit 1
  end
end
