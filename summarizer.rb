#!/usr/bin/env ruby
require 'json'
require 'net/http'

class Summarizer
  ANALYZABLE_EXTENSIONS = %w[.rb .ex .exs].freeze
  OLLAMA_URL = 'http://localhost:11434/api/generate'

  def self.run(commit_msg_file, commit_source)
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
      The code may contain JSON-like syntax that is actually part of another language - do not get confused by this.
      
      Summarize what changed in this diff:
      - What was removed (lines starting with -)
      - What was added (lines starting with +)
      - Note any configuration value changes
      - Note any code moves between files
      
      Respond in JSON format with these keys:
      {
          "issues": ["list of changes made"],
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

    prompt = <<~PROMPT
      You are a commit message generator. I will show you the actual git diff below.
      Generate a commit message for ONLY these specific changes.
      
      When analyzing the diff:
      1. Pay attention to files being modified - look at the file paths
      2. Note if code is being moved between files:
         - Track which lines are removed from which file
         - Track which lines are added to which file
         - Don't assume all similar lines are moves
      3. Watch for value changes when code is moved:
         - Look at the actual values in the '-' and '+' lines
         - Check what variables are assigned to
         - Note if a value is using a different variable (e.g., four_hours -> one_day)
         - Track the actual value of each variable (e.g., four_hours = 4 * 60 * 60 * 1000)
         - Compare the old and new values carefully
      4. For configuration changes:
         - List EACH configuration value that was changed
         - For each change, document:
           * The exact name of the config
           * Which file it was removed from (if moved/removed)
           * Which file it was added to (if moved/added)
           * The old value or variable it used (with actual value)
           * The new value or variable it uses (with actual value)
           * Include units and actual numeric values
           * Note if the value source changed (e.g., from four_hours to one_day)
         - Note if values were added, removed, or modified
      
      Rules for the commit message:
      1. Use imperative mood (e.g., "Add feature" not "Added feature")
      2. First line should be a summary under 50 characters
      3. Follow with a blank line and more detailed description if needed
      4. Group related changes together
      5. Focus on the "what" and "why", not the "how"
      6. Mention file moves explicitly (e.g., "Move config from X to Y")
      7. List configuration changes in bullet points:
         - One bullet per configuration change
         - Format: "* config_name: [removed from old_file] old_value (variable = actual_value) -> [added to new_file] new_value (variable = actual_value)"
         - Include both the variable name and its calculated value
         - Mark new configs as "added"
      
      IMPORTANT: 
      - Return ONLY the commit message text
      - Do not include any text like "Here is the commit message" or "Based on the changes"
      - Do not wrap the message in quotes or code blocks
      - Do not add any explanations before or after the message
      - Do not add any formatting like dashes or headers
      - Do not explain your reasoning or methodology
      - The first line of your response must be the commit summary
      - Exactly follow this format:
        Summary line under 50 chars
        
        * First change detail
        * Second change detail
        * Additional details if needed
      
      GIT DIFF TO ANALYZE:
      ```
      #{diffs}
      ```
    PROMPT

    message = call_ollama(prompt, diffs)
    return nil if message.nil?

    if message.is_a?(Hash) && message['response']
      message['response'].to_s.strip
    elsif message.is_a?(String)
      message.strip
    else
      puts "Warning: Unexpected response format from Ollama"
      nil
    end
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
end

commit_msg_file = ARGV[0]
commit_source = ARGV[1]
Summarizer.run(commit_msg_file, commit_source) if $PROGRAM_NAME == __FILE__