#!/usr/bin/env ruby
require 'json'
require 'net/http'

class Summarizer
  VERSION = "1.0.0"
  ANALYZABLE_EXTENSIONS = %w[.rb .ex .exs].freeze
  OLLAMA_URL = 'http://localhost:11434/api/generate'

  def self.run(commit_msg_file, commit_source)
    if ARGV.include?('--version') || ARGV.include?('-v')
      puts "Git Commit Message Generator v#{VERSION}"
      exit(0)
    end
    
    new.run(commit_msg_file, commit_source)
  end

  def run(commit_msg_file, commit_source)
    # Skip if this is a merge, amend, or other special commit
    return if commit_source && !commit_source.empty?

    if staged_files.empty?
      puts "No files staged for commit"
      exit(0)
    end

    # First check for issues
    if analyze_files
      puts "\n⛔ Issues found in code. Please fix them before committing."
      exit(1)
    end

    # Generate and set the commit message
    message = generate_commit_message
    if message
      # Preserve any existing comments in the commit message file
      existing_content = File.read(commit_msg_file)
      comments = existing_content.lines.select { |line| line.start_with?('#') }.join

      # Write the new message followed by any existing comments
      File.write(commit_msg_file, "#{message.strip}\n\n#{comments}")
      
      puts "\n✅ Commit message generated and loaded into editor."
      puts "Review the message, make any needed changes, then save and close."
    end
  end

  private

  def staged_files
    @staged_files ||= `git diff --cached --name-only --diff-filter=ACMR`.split("\n")
  end

  def get_file_diff(file_path)
    `git diff --cached #{file_path}`.strip
  rescue => e
    puts "Error getting diff for #{file_path}: #{e.message}"
    ""
  end

  def analyze_files
    has_issues = false

    staged_files.each do |file_path|
      next unless ANALYZABLE_EXTENSIONS.include?(File.extname(file_path))

      puts "\nAnalyzing #{file_path}..."
      content = get_file_diff(file_path)
      next if content.empty?

      analysis = analyze_with_ollama(content)
      
      if analysis["issues"]&.any?
        puts "\nIssues found in #{file_path}:"
        analysis["issues"].each { |issue| puts "- #{issue}" }
        puts "Severity: #{analysis['severity'] || 'unknown'}"
        
        has_issues = true if analysis["should_block"]
      end
    end

    has_issues
  end

  def analyze_with_ollama(content)
    prompt = <<~PROMPT
      You are analyzing a git diff. Focus ONLY on the changes (lines starting with + or -).
      
      Summarize what changed in this diff:
      - What was removed (lines starting with -)
      - What was added (lines starting with +)
      - Note any configuration value changes
      - Note any code moves between files
      
      For each file in the diff, list the specific changes made.
      
      Respond in JSON format with this structure:
      {
        "issues": [
          {
            "file": "filename.ext",
            "changes": ["specific change 1", "specific change 2"]
          }
        ],
        "severity": "low",
        "should_block": false
      }
      
      IMPORTANT: 
      - Focus on describing what changed, not judging the changes
      - Your response must be valid JSON
      - Start with { and end with }
      - Do not include any explanation text
      - Keep descriptions brief and factual
      
      GIT DIFF TO ANALYZE:
      ```
      #{content}
      ```
    PROMPT

    result = call_ollama(prompt, content)
    
    # Handle case where result is a string
    unless result.is_a?(Hash)
      return {
        "issues" => ["Error: Unexpected response format from Ollama"],
        "severity" => "low",
        "should_block" => false
      }
    end

    # Ensure we have a proper hash with expected keys
    {
      "issues" => (result["issues"] || []),
      "severity" => "low",
      "should_block" => false
    }
  end

  def generate_commit_message
    diffs = staged_files.map do |file|
      diff = get_file_diff(file)
      "File: #{file}\n#{diff}" if diff.length > 0
    end.compact.join("\n\n")

    return nil if diffs.empty?

    # First, get just the summary
    summary_prompt = <<~PROMPT
      Write ONLY a one-line summary (under 50 chars) for this git commit.
      Use imperative mood ("Add" not "Added").
      DO NOT include any other text, just the summary line.
      
      Changes:
      ```
      #{diffs}
      ```
    PROMPT

    summary_response = call_ollama(summary_prompt, diffs)
    return nil if summary_response.nil?

    summary = if summary_response.is_a?(Hash) && summary_response['response']
      summary_response['response'].to_s
    elsif summary_response.is_a?(String)
      summary_response
    else
      "Update configuration settings"  # Fallback
    end

    # Clean up summary
    summary = summary
      .sub(/^(Here'?s|The|This is|I have|Generated|Based on).*?(summary|message|diff).*?\n/i, '')
      .gsub(/`([^`]+)`/, '\1')
      .strip
      .split("\n").first || "Update configuration settings"
    
    # Truncate if too long
    summary = summary[0..49] if summary.length > 50

    # Now, get the bullet points
    bullets_prompt = <<~PROMPT
      List ONLY the specific changes in this git diff as bullet points.
      
      IMPORTANT: Pay close attention to the + and - lines in the diff:
      - Lines starting with - are REMOVED
      - Lines starting with + are ADDED
      
      For each change:
      1. Check which file it's in (look at the file path)
      2. Check if code is being moved between files
      3. For configuration changes, note:
         - The exact name of the config
         - Which file it was removed from
         - Which file it was added to
         - The actual values (check the variables)
      
      Each bullet should:
      - Start with "* "
      - Be specific about what changed
      - Include old and new values
      - Not use backticks
      - Not include explanations
      
      Example format:
      * Move config from dev.exs to runtime.exs
      * Change database timeout from 30s to 60s
      
      DO NOT include any text before or after the bullet points.
      DO NOT include a summary line.
      DO NOT include explanations or comments.
      
      Changes:
      ```
      #{diffs}
      ```
    PROMPT

    bullets_response = call_ollama(bullets_prompt, diffs)
    return nil if bullets_response.nil?

    bullets = if bullets_response.is_a?(Hash) && bullets_response['response']
      bullets_response['response'].to_s
    elsif bullets_response.is_a?(String)
      bullets_response
    else
      "* Update configuration settings"  # Fallback
    end

    # Clean up bullets
    bullets = bullets
      .sub(/^(Here'?s|The|This is|I have|Generated|Based on).*?(bullet|list|change|diff).*?\n/i, '')
      .gsub(/`([^`]+)`/, '\1')
      .gsub(/\(variable = actual value\)/, '')
      .strip

    # Verify bullet points against the diff
    verified_bullets = []
    
    # First, let's extract some key information from the diff
    config_moves = {}
    
    # Look for removed configs in dev.exs
    diffs.scan(/File: config\/dev\.exs.*?^-config :(\w+), (\w+): (\w+)/m) do |app, key, value|
      config_moves["#{app}.#{key}"] ||= {}
      config_moves["#{app}.#{key}"][:removed_from] = "dev.exs"
      config_moves["#{app}.#{key}"][:old_value] = value
    end
    
    # Look for added configs in config.exs
    diffs.scan(/File: config\/config\.exs.*?^\+config :(\w+), (\w+): (\w+)/m) do |app, key, value|
      config_moves["#{app}.#{key}"] ||= {}
      config_moves["#{app}.#{key}"][:added_to] = "config.exs"
      config_moves["#{app}.#{key}"][:new_value] = value
    end
    
    # Look for variable definitions
    variables = {}
    diffs.scan(/^\+([\w_]+) = \(([\d\s\*\+]+)\)/m) do |var, value|
      variables[var] = value
    end
    diffs.scan(/^-([\w_]+) = \(([\d\s\*\+]+)\)/m) do |var, value|
      variables[var] ||= value
    end
    
    # Now create verified bullets based on what we found
    config_moves.each do |config, details|
      if details[:removed_from] && details[:added_to]
        old_val = details[:old_value]
        new_val = details[:new_value]
        
        # Try to resolve variable values
        old_val_desc = variables[old_val] ? "#{old_val} (#{humanize_time(variables[old_val])})" : old_val
        new_val_desc = variables[new_val] ? "#{new_val} (#{humanize_time(variables[new_val])})" : new_val
        
        verified_bullets << "* Move #{config} from #{details[:removed_from]} to #{details[:added_to]}, changing value from #{old_val_desc} to #{new_val_desc}"
      elsif details[:removed_from]
        verified_bullets << "* Remove #{config} from #{details[:removed_from]}"
      elsif details[:added_to]
        new_val = details[:new_value]
        new_val_desc = variables[new_val] ? "#{new_val} (#{humanize_time(variables[new_val])})" : new_val
        verified_bullets << "* Add #{config} to #{details[:added_to]} with value #{new_val_desc}"
      end
    end
    
    # If we couldn't verify anything, use the original bullets
    if verified_bullets.empty?
      # Process each bullet from the model
      bullets.lines.each do |line|
        line = line.strip
        next if line.empty?
        
        # Check if the line mentions a change from X to Y
        if line =~ /from (.+) to (.+)/i
          from_value = $1
          to_value = $2
          
          # Check if the diff contains these values
          if diffs.include?(from_value) && diffs.include?(to_value)
            # Check if the direction is correct
            from_lines = diffs.lines.select { |l| l.start_with?('-') && l.include?(from_value) }
            to_lines = diffs.lines.select { |l| l.start_with?('+') && l.include?(to_value) }
            
            if from_lines.any? && to_lines.any?
              verified_bullets << line
            else
              # Try reversing the direction
              reversed = line.gsub(/from #{from_value} to #{to_value}/i, "from #{to_value} to #{from_value}")
              verified_bullets << reversed
            end
          else
            # If we can't verify, include it anyway
            verified_bullets << line
          end
        else
          verified_bullets << line
        end
      end
    end
    
    # Use verified bullets or fall back to original
    bullets = verified_bullets.any? ? verified_bullets.join("\n") : bullets

    # Combine summary and bullets
    message = "#{summary}\n\n#{bullets}"
    
    # Final cleanup and formatting
    formatted_lines = []
    
    # Process each line to enforce character limits
    message.lines.each_with_index do |line, index|
      line = line.to_s.rstrip  # Add to_s to handle nil
      
      if index == 0
        # Summary line: 50 chars max
        formatted_lines << line[0..49] if line.length > 0
      else
        # Body lines: 72 chars max
        if line.length > 72
          # For bullet points, preserve the bullet and wrap at word boundaries
          if line.start_with?('* ')
            # Keep the bullet for the first line
            current_line = line[0..71]
            
            # Try to find a good breaking point
            if current_line.rindex(' ', 70) && current_line.rindex(' ', 70) > 2
              break_at = current_line.rindex(' ', 70)
              formatted_lines << current_line[0..break_at]
              remaining = line[(break_at+1)..]
            else
              formatted_lines << current_line
              remaining = line[72..]
            end
            
            # Wrap remaining text with proper indentation at word boundaries
            while remaining && remaining.length > 0
              if remaining.length <= 70
                formatted_lines << "  #{remaining}"
                break
              end
              
              # Find word boundary
              if remaining.rindex(' ', 69) && remaining.rindex(' ', 69) > 0
                break_at = remaining.rindex(' ', 69)
                formatted_lines << "  #{remaining[0..break_at]}"
                remaining = remaining[(break_at+1)..]
              else
                formatted_lines << "  #{remaining[0..69]}"
                remaining = remaining[70..]
              end
            end
          else
            # Regular line wrapping at word boundaries
            formatted_lines << line[0..71]
          end
        else
          formatted_lines << line
        end
      end
    end
    
    formatted_lines.join("\n").gsub(/\n{3,}/, "\n\n").strip
  end

  def call_ollama(prompt, content)
    request_body = {
      model: "codellama",
      prompt: prompt,
      stream: false
    }

    uri = URI(OLLAMA_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    
    # Longer timeouts
    http.read_timeout = 180  # 3 minutes
    http.open_timeout = 10   # 10 seconds for initial connection
    
    # Check if Ollama is responding
    begin
      puts "Checking connection to Ollama at #{OLLAMA_URL}..."
      http.start do |h|
        check_request = Net::HTTP::Get.new(URI(OLLAMA_URL))
        h.request(check_request)
      end
      puts "✓ Successfully connected to Ollama"
    rescue => e
      puts "⚠️  Could not connect to Ollama: #{e.message}"
      puts "Please ensure Ollama is running at #{OLLAMA_URL}"
      return {
        "issues" => ["Could not connect to Ollama service"],
        "severity" => "high",
        "should_block" => true
      }
    end
    
    puts "Sending request to Ollama (this may take a few minutes)..."
    request = Net::HTTP::Post.new(uri)
    request.content_type = 'application/json'
    request.body = request_body.to_json

    response = http.request(request)
    result = JSON.parse(response.body)
    
    if result['response']
      if prompt.include?("GIT DIFF TO ANALYZE") && !prompt.include?("commit message generator")
        # For analysis requests, try to parse as JSON
        begin
          # Clean up the response to extract just the JSON part
          json_str = result['response'].strip
          # Log the raw response for debugging
          puts "Raw Ollama response: #{json_str}" if ENV['DEBUG']
          
          # Find the JSON part more reliably
          start_idx = json_str.index('{')
          end_idx = json_str.rindex('}')
          
          if start_idx.nil? || end_idx.nil?
            puts "Could not find JSON in response: #{json_str}"
            return {
              "issues" => ["Response did not contain valid JSON"],
              "severity" => "high",
              "should_block" => true
            }
          end
          
          json_str = json_str[start_idx..end_idx]
          parsed_response = JSON.parse(json_str)
          
          # Validate the response has the required keys
          unless parsed_response.key?("issues") && parsed_response.key?("severity") && parsed_response.key?("should_block")
            return {
              "issues" => ["Invalid response format from Ollama: Missing required fields"],
              "severity" => "high",
              "should_block" => true
            }
          end
          parsed_response
        rescue JSON::ParserError, NoMethodError => e
          puts "Failed to parse JSON response: #{e.message}"
          puts "Response was: #{result['response']}"
          {
            "issues" => ["Invalid JSON response from Ollama"],
            "severity" => "high",
            "should_block" => true
          }
        end
      else
        # For commit message requests, just return the response text
        result['response']
      end
    else
      # Return a default error response if no response field
      {
        "issues" => ["No response received from Ollama"],
        "severity" => "high",
        "should_block" => true
      }
    end
  rescue Net::ReadTimeout, Net::OpenTimeout => e
    puts "Timeout connecting to Ollama: #{e.message}"
    puts "The operation took too long to complete"
    {
      "issues" => ["Timeout error: Operation took too long to complete"],
      "severity" => "high",
      "should_block" => true
    }
  rescue => e
    puts "Error calling Ollama: #{e.message}"
    {
      "issues" => ["Error analyzing code: #{e.message}"],
      "severity" => "high",
      "should_block" => true
    }
  end

  # Helper method to convert milliseconds to human-readable time
  def humanize_time(expression)
    # Try to evaluate the expression
    begin
      if expression =~ /(\d+)\s*\*\s*(\d+)\s*\*\s*(\d+)\s*\*\s*(\d+)/
        hours = $1.to_i
        result = "#{hours} hours"
        return result
      elsif expression =~ /(\d+)\s*\*\s*(\d+)\s*\*\s*(\d+)/
        minutes = $1.to_i
        result = "#{minutes} minutes"
        return result
      else
        return expression
      end
    rescue
      return expression
    end
  end
end

commit_msg_file = ARGV[0]
commit_source = ARGV[1]
Summarizer.run(commit_msg_file, commit_source) if $PROGRAM_NAME == __FILE__