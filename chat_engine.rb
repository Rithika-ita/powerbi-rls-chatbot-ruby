require 'json'
require 'rest-client'
require_relative 'config'
require_relative 'powerbi_service'

module ChatEngine
  extend self

  def logger
    Settings.logger
  end

  # ── Foundry Token Acquisition (Client Credentials) ───────────────────────────
  #
  # Azure AI Foundry does NOT support OBO (On-Behalf-Of) flow.
  # See: https://learn.microsoft.com/en-us/answers/questions/5839453
  #
  # Instead, we use client credentials (app ID + secret) with Azure RBAC.
  # The service principal must have "Cognitive Services User" role (or similar)
  # on the Azure AI resource via Access Control (IAM).
  #
  # RLS context is passed as message content to the Foundry agent.

  def acquire_foundry_token
    tenant_id = Settings.azure_tenant_id
    client_id = Settings.azure_client_id
    client_secret = Settings.azure_client_secret
    scope = Settings.foundry_scope

    raise "Foundry auth requires AZURE_TENANT_ID, AZURE_CLIENT_ID, and AZURE_CLIENT_SECRET" if
      tenant_id.nil? || client_id.nil? || client_secret.nil?
    raise "Foundry auth requires FOUNDRY_SCOPE" if scope.nil? || scope.strip.empty?

    url = "https://login.microsoftonline.com/#{tenant_id}/oauth2/v2.0/token"

    body = {
      client_id: client_id,
      client_secret: client_secret,
      grant_type: "client_credentials",
      scope: scope
    }

    logger.info "Acquiring Foundry token via client credentials (scope: #{scope})"

    response = RestClient::Request.execute(
      method: :post,
      url: url,
      payload: body,
      max_redirects: 0
    )
    result = JSON.parse(response.body)

    if result['error']
      logger.error "Foundry token error: #{result['error']} - #{result['error_description']}"
      raise "Foundry token acquisition failed: #{result['error_description']}"
    end

    token = result['access_token']
    if token.nil? || token.strip.empty?
      logger.error "Foundry token response missing access_token: #{result.inspect}"
      raise "Foundry token acquisition failed: no access token in response"
    end

    logger.info "Foundry token acquired, expires in #{result['expires_in']} seconds"
    token
  rescue RestClient::ExceptionWithResponse => e
    logger.error "Foundry token HTTP error #{e.response.code}: #{e.response.body[0..500]}"
    raise "Foundry token error (#{e.response.code}): #{e.response.body[0..200]}"
  rescue => e
    logger.error "Foundry token acquisition failed: #{e.class} - #{e.message}"
    raise "Foundry token error: #{e.message}"
  end

  # ── Call Foundry Agent API (with Knowledge Source) ──────────────────────────────
  #
  # Uses Azure AI Foundry Agents API instead of generic chat/completions.
  # This invokes the configured agent (asst_tOWViO8FUKUoFFlpwFen3Ea4) with
  # its knowledge source (fabric-analytics-dataagent) attached.
  #
  # Pattern: Creates a thread for the conversation, sends messages to it,
  # and retrieves agent responses that use the knowledge source.

  def call_foundry_agent_api(user_message, foundry_token, rls_username, conversation_history = [])
    call_foundry_agent_api_once(user_message, foundry_token, rls_username, conversation_history)
  rescue => e
    raise e unless retryable_foundry_server_error?(e)

    logger.warn "Foundry Agent server error for #{rls_username}; retrying once with a fresh thread"
    reset_agent_thread(rls_username)
    call_foundry_agent_api_once(user_message, foundry_token, rls_username, conversation_history, force_new_thread: true)
  end

  def call_foundry_agent_api_once(user_message, foundry_token, rls_username, conversation_history = [], force_new_thread: false)
    foundry_url = Settings.foundry_endpoint&.chomp("/")
    raise "FOUNDRY_ENDPOINT is not configured." if foundry_url.nil? || foundry_url.strip.empty?

    agent_id = Settings.foundry_agent_id
    raise "FOUNDRY_AGENT_ID is not configured." if agent_id.nil? || agent_id.strip.empty?

    headers = {
      content_type: :json,
      accept: :json,
      Authorization: "Bearer #{foundry_token}"
    }

    # Build RLS context for the message
    rls_config = load_rls_config
    message_content = build_foundry_message_content(user_message, rls_username, rls_config)

    # Use a fresh thread by default to keep API behavior closer to playground.
    effective_force_new = force_new_thread || !Settings.foundry_reuse_threads?
    thread_id = get_or_create_agent_thread(rls_username, foundry_token: foundry_token, force_new: effective_force_new)
    api_version = "2025-05-01"

    # Post message to the agent thread
    messages_url = "#{foundry_url}/threads/#{thread_id}/messages?api-version=#{api_version}"
    message_body = {
      role: "user",
      content: message_content
    }

    logger.info "Sending message to Foundry Agent (thread: #{thread_id}, agent: #{agent_id})"
    logger.debug "Message: #{message_content[0..200]}"

    response = RestClient.post(messages_url, message_body.to_json, headers)
    message_result = JSON.parse(response.body)
    logger.info "Foundry message accepted: #{message_result['id'] || '(no id returned)'}"

    # Run the agent to generate response
    run_url = "#{foundry_url}/threads/#{thread_id}/runs?api-version=#{api_version}"
    run_body = {
      assistant_id: agent_id
    }

    logger.info "Creating Foundry agent run for thread #{thread_id}"
    run_response = RestClient.post(run_url, run_body.to_json, headers)
    run_result = JSON.parse(run_response.body)
    logger.info "Foundry run created: #{run_result['id'] || '(no id returned)'}"

    # Poll for completion (with timeout)
    run_id = run_result["id"]
    response_content = poll_agent_run_completion(foundry_url, thread_id, run_id, foundry_token, headers, api_version)

    logger.info "Agent response: #{response_content[0..200]}"
    response_content
  rescue RestClient::ExceptionWithResponse => e
    logger.error format_foundry_http_error("Foundry Agent API", e)
    raise build_foundry_http_error("Foundry Agent", e)
  rescue => e
    logger.error "Foundry Agent API failed: #{e.class} - #{e.message}"
    raise e
  end

  # ── Poll Agent Run for Completion ─────────────────────────────────────────────

  def poll_agent_run_completion(foundry_url, thread_id, run_id, foundry_token, headers, api_version, timeout_seconds = 120)
    start_time = Time.now
    poll_interval = 2  # seconds
    last_status = nil

    loop do
      elapsed = Time.now - start_time
      if elapsed > timeout_seconds
        logger.error "Agent run timeout after #{timeout_seconds}s"
        raise "Agent run did not complete within #{timeout_seconds} seconds"
      end

      run_url = "#{foundry_url}/threads/#{thread_id}/runs/#{run_id}?api-version=#{api_version}"
      run_response = RestClient.get(run_url, headers)
      run_result = JSON.parse(run_response.body)

      status = run_result["status"]
      last_error = run_result["last_error"]
      if status != last_status
        logger.info "Agent run #{run_id} status: #{status}"
        last_status = status
      end
      if last_error
        logger.error "Agent run last_error: code=#{last_error['code']} message=#{last_error['message']}"
      end

      if status == "completed" || status == "success"
        # Log run steps for diagnostics (tool calls, errors, etc.)
        steps = fetch_run_steps(foundry_url, thread_id, run_id, headers, api_version)
        log_run_steps(steps)

        tool_failure = extract_tool_failure_from_steps(steps)
        if tool_failure
          logger.error "Fabric Data Agent tool failed: #{tool_failure}"
          raise "Fabric Data Agent error: #{tool_failure}"
        end

        # Retrieve the last message from the thread
        messages_url = "#{foundry_url}/threads/#{thread_id}/messages?api-version=#{api_version}"
        messages_response = RestClient.get(messages_url, headers)
        messages_result = JSON.parse(messages_response.body)

        # Get the most recent assistant message (messages are returned newest-first)
        messages = messages_result["data"] || messages_result["messages"] || []
        assistant_message = messages.find { |msg| msg["role"] == "assistant" }

        if assistant_message
          content = assistant_message["content"]
          # Handle Foundry response: may be array of objects, or string
          if content.is_a?(Array)
            # Extract text from each item if present
            text_values = content.map do |item|
              if item.is_a?(Hash) && item["type"] == "text" && item["text"].is_a?(Hash)
                item["text"]["value"]
              elsif item.is_a?(String)
                item
              else
                item.to_s
              end
            end
            return text_values.join("\n")
          elsif content.is_a?(String)
            return content
          else
            return content.to_s
          end
        else
          logger.warn "No assistant message found in thread"
          return "Agent processed request but did not return a message."
        end
      elsif status == "failed" || status == "error"
        steps = fetch_run_steps(foundry_url, thread_id, run_id, headers, api_version)
        log_run_steps(steps)
        error_detail = last_error ? "#{last_error['code']}: #{last_error['message']}" : status
        logger.error "Agent run failed: #{error_detail}"
        raise "Agent run failed: #{error_detail}"
      end

      sleep(poll_interval)
    end
  rescue RestClient::ExceptionWithResponse => e
    logger.error format_foundry_http_error("Foundry Agent poll", e)
    raise build_foundry_http_error("Agent poll", e)
  end

  # ── Run Steps Diagnostics ──────────────────────────────────────────────────

  def fetch_run_steps(foundry_url, thread_id, run_id, headers, api_version)
    steps_url = "#{foundry_url}/threads/#{thread_id}/runs/#{run_id}/steps?api-version=#{api_version}"
    steps_response = RestClient.get(steps_url, headers)
    steps_result = JSON.parse(steps_response.body)
    steps_result["data"] || []
  end

  def log_run_steps(steps)
    logger.info "Agent run steps (#{steps.length} total):"
    steps.each_with_index do |step, i|
      step_type = step["type"]
      step_status = step["status"]
      step_detail = step["step_details"] || {}
      last_err = step["last_error"]

      logger.info "  Step #{i + 1}: type=#{step_type} status=#{step_status}"
      if last_err
        logger.error "  Step #{i + 1} error: code=#{last_err['code']} message=#{last_err['message']}"
      end
      if step_type == "tool_calls"
        tool_calls = step_detail["tool_calls"] || []
        tool_calls.each do |tc|
          tc_type = tc["type"]
          tc_id = tc["id"]
          # Log tool call details based on type
          if tc_type == "bing_grounding" || tc_type == "fabric_dataagent" || tc_type == "code_interpreter"
            logger.info "    Tool: #{tc_type} (#{tc_id})"
            logger.info "    Input: #{tc.dig(tc_type, 'input')&.to_s&.slice(0, 500)}"
            logger.info "    Output: #{tc.dig(tc_type, 'output')&.to_s&.slice(0, 500)}"
          else
            logger.info "    Tool: #{tc_type} (#{tc_id}) detail: #{tc.to_json[0..500]}"
          end
        end
      end
    end
  rescue => e
    logger.warn "Failed to retrieve run steps: #{e.class} - #{e.message}"
  end

  def extract_tool_failure_from_steps(steps)
    steps.each do |step|
      next unless step["type"] == "tool_calls"

      (step.dig("step_details", "tool_calls") || []).each do |tool_call|
        next unless tool_call["type"] == "fabric_dataagent"

        output = tool_call.dig("fabric_dataagent", "output").to_s
        next if output.strip.empty?
        next unless fabric_tool_output_indicates_failure?(output)

        return sanitize_tool_output(output)
      end
    end

    nil
  end

  def sanitize_tool_output(output)
    cleaned = output.gsub(/【[^】]+】/, '').strip
    cleaned = cleaned.gsub(/\s+/, ' ')
    cleaned
  end

  def fabric_tool_output_indicates_failure?(output)
    normalized = output.to_s.downcase

    failure_markers = [
      'technical issue',
      'technical error',
      'internal error',
      'query failed',
      'failed to',
      'unable to',
      'could not',
      "couldn't",
      'no data was retrieved',
      'temporary issue',
      'try asking your question again',
      'try your request again'
    ]

    failure_markers.any? { |marker| normalized.include?(marker) }
  end

  # ── Thread Management ─────────────────────────────────────────────────────────

  def reset_agent_thread(user_identifier)
    @agent_threads ||= {}
    old_thread = @agent_threads.delete(user_identifier)
    logger.info "Reset agent thread for #{user_identifier} (was: #{old_thread})"
  end

  def get_or_create_agent_thread(user_identifier, foundry_token: nil, force_new: false)
    api_version = "2025-05-01"
    # Store thread IDs in class variable (in-memory per Ruby process)
    # For production, consider Redis or database for persistence
    @agent_threads ||= {}

    if force_new
      reset_agent_thread(user_identifier)
    end

    unless @agent_threads[user_identifier]
      # Create a new thread for this user
      foundry_url = Settings.foundry_endpoint&.chomp("/")
      foundry_token ||= acquire_foundry_token

      headers = {
        content_type: :json,
        accept: :json,
        Authorization: "Bearer #{foundry_token}"
      }

      threads_url = "#{foundry_url}/threads?api-version=#{api_version}"
      thread_body = {
        metadata: { user: user_identifier }
      }

      logger.info "Creating new agent thread for #{user_identifier}"
      response = RestClient.post(threads_url, thread_body.to_json, headers)
      result = JSON.parse(response.body)

      thread_id = result["id"]
      raise "Foundry thread creation returned no id" if thread_id.nil? || thread_id.strip.empty?

      @agent_threads[user_identifier] = thread_id

      logger.info "New thread created: #{thread_id}"
    end

    @agent_threads[user_identifier]
  rescue => e
    logger.error "Failed to create agent thread: #{e.class} - #{e.message}"
    raise e
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  def load_rls_config
    @rls_config ||= begin
      path = File.join(File.dirname(__FILE__), "rls_config.json")
      if File.exist?(path)
        config = JSON.parse(File.read(path))
        logger.info "RLS config loaded: filter on #{config['filter_table']}[#{config['filter_column']}] via #{config['identity_table']}[#{config['identity_column']}]"
        config
      end
    end
  end

  # ── Main Entry Point ──────────────────────────────────────────────────────────

  def chat(user_message, rls_username, conversation_history = [])
    logger.info "Using Foundry Agent for #{rls_username} with knowledge source (client credentials)"

    foundry_token = acquire_foundry_token

    answer = call_foundry_agent_api(user_message, foundry_token, rls_username, conversation_history)

    logger.info "Foundry Agent answer for #{rls_username}: #{answer[0..200]}"

    {
      "answer" => answer,
      "data" => nil
    }
  rescue => e
    logger.error "ChatEngine error: #{e.class} - #{e.message}"
    raise e
  end

  # ── RLS Diagnostic ────────────────────────────────────────────────────────────
  #
  # Sends the same query twice on separate threads:
  #   1) WITH RLS filter context appended to the message
  #   2) WITHOUT any RLS context (plain question)
  #
  # Comparing the two results proves whether the text-based RLS injection
  # is causing the Fabric Data Agent to fail.

  def diagnose_rls(user_message, rls_username)
    foundry_token = acquire_foundry_token
    results = {}

    # Run both tests in parallel to halve total wait time
    threads = []

    # ── Test 1: WITH RLS context (normal path) ──
    threads << Thread.new do
      begin
        logger.info "[RLS-DIAG] Test 1: WITH RLS filter for #{rls_username}"
        thread_with = create_fresh_thread(foundry_token, "diag-with-rls-#{rls_username}")
        answer_with = run_agent_on_thread(user_message, foundry_token, rls_username, thread_with, inject_rls: true)
        { "status" => "ok", "answer" => answer_with }
      rescue => e
        logger.error "[RLS-DIAG] WITH RLS failed: #{e.class} - #{e.message}"
        { "status" => "error", "error" => e.message }
      end
    end

    # ── Test 2: WITHOUT RLS context ──
    threads << Thread.new do
      begin
        logger.info "[RLS-DIAG] Test 2: WITHOUT RLS filter (plain query)"
        thread_without = create_fresh_thread(foundry_token, "diag-no-rls-#{rls_username}")
        answer_without = run_agent_on_thread(user_message, foundry_token, rls_username, thread_without, inject_rls: false)
        { "status" => "ok", "answer" => answer_without }
      rescue => e
        logger.error "[RLS-DIAG] WITHOUT RLS failed: #{e.class} - #{e.message}"
        { "status" => "error", "error" => e.message }
      end
    end

    # Wait for both to finish (max 120s each, but running concurrently)
    thread_results = threads.map(&:value)
    results["with_rls"] = thread_results[0]
    results["without_rls"] = thread_results[1]

    # ── Verdict ──
    both_failed  = results.dig("with_rls", "status") == "error" && results.dig("without_rls", "status") == "error"
    only_rls_failed = results.dig("with_rls", "status") == "error" && results.dig("without_rls", "status") == "ok"
    rls_empty    = results.dig("with_rls", "answer")&.include?("technical error") || results.dig("with_rls", "answer")&.include?("†source")
    no_rls_ok    = results.dig("without_rls", "status") == "ok" && !results.dig("without_rls", "answer")&.include?("technical error")

    if both_failed
      results["verdict"] = "BOTH_FAILED - Fabric Data Agent is unreachable or broken regardless of RLS. Check agent connection / capacity status."
    elsif only_rls_failed
      results["verdict"] = "RLS_CAUSES_FAILURE - Query works without RLS but fails with it. The text-based RLS filter is the problem."
    elsif rls_empty && no_rls_ok
      results["verdict"] = "RLS_CAUSES_EMPTY - Agent returns data without RLS but gives citation/error with RLS. The text-based RLS filter is likely confusing the agent."
    else
      results["verdict"] = "INCONCLUSIVE - Both requests returned similar results. RLS text injection may not be the issue. Compare answers below."
    end

    logger.info "[RLS-DIAG] Verdict: #{results['verdict']}"
    results
  end

  private

  def create_fresh_thread(foundry_token, label)
    foundry_url = Settings.foundry_endpoint&.chomp("/")
    api_version = "2025-05-01"
    headers = { content_type: :json, accept: :json, Authorization: "Bearer #{foundry_token}" }

    thread_body = { metadata: { diagnostic: label } }
    response = RestClient.post("#{foundry_url}/threads?api-version=#{api_version}", thread_body.to_json, headers)
    JSON.parse(response.body)["id"]
  end

  def run_agent_on_thread(user_message, foundry_token, rls_username, thread_id, inject_rls:)
    foundry_url = Settings.foundry_endpoint&.chomp("/")
    agent_id    = Settings.foundry_agent_id
    api_version = "2025-05-01"
    headers = { content_type: :json, accept: :json, Authorization: "Bearer #{foundry_token}" }

    message_content = user_message
    if inject_rls
      rls_config = load_rls_config
      message_content = build_foundry_message_content(user_message, rls_username, rls_config)
    end

    logger.info "[RLS-DIAG] Sending (inject_rls=#{inject_rls}): #{message_content[0..300]}"

    # Post message
    RestClient.post(
      "#{foundry_url}/threads/#{thread_id}/messages?api-version=#{api_version}",
      { role: "user", content: message_content }.to_json,
      headers
    )

    # Run agent
    run_response = RestClient.post(
      "#{foundry_url}/threads/#{thread_id}/runs?api-version=#{api_version}",
      { assistant_id: agent_id }.to_json,
      headers
    )
    run_id = JSON.parse(run_response.body)["id"]

    poll_agent_run_completion(foundry_url, thread_id, run_id, foundry_token, headers, api_version)
  end

  def retryable_foundry_server_error?(error)
    message = error.message.to_s
    return true if message.include?("Foundry Agent error (500)")
    return true if message.include?("Agent poll error (500)")

    false
  end

  def format_foundry_http_error(prefix, exception)
    code = exception.response.code
    body = exception.response.body.to_s
    request_id = extract_foundry_request_id(body)

    message = "#{prefix} HTTP error #{code}: #{body[0..500]}"
    message += " (request_id=#{request_id})" if request_id
    message
  end

  def build_foundry_http_error(prefix, exception)
    code = exception.response.code
    body = exception.response.body.to_s
    request_id = extract_foundry_request_id(body)

    message = "#{prefix} error (#{code})"
    message += " [request_id=#{request_id}]" if request_id
    message += ": #{body[0..400]}"
    message
  end

  def extract_foundry_request_id(body)
    parsed = JSON.parse(body)
    parsed.dig("error", "message")&.match(/request ID\s+([a-f0-9]+)/i)&.captures&.first
  rescue JSON::ParserError
    nil
  end

  def build_foundry_message_content(user_message, rls_username, rls_config)
    return user_message unless rls_config && rls_username

    case Settings.foundry_rls_context_mode
    when 'off', 'none', 'disabled'
      user_message
    when 'raw'
      "#{user_message}\n\n[Context: User #{rls_username} - Filter results to #{rls_config['identity_table']}[#{rls_config['identity_column']}] = '#{rls_username}']"
    else
      [
        user_message,
        "User context: #{rls_username}.",
        "Use this identity only as business context.",
        "Do not restate or translate the user context into an explicit filter expression unless the connected data source requires it."
      ].join("\n\n")
    end
  end

end
