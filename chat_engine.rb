require 'json'
require 'rest-client'
require_relative 'config'

module ChatEngine
  extend self

  def logger
    Settings.logger
  end

  def generate_dax(user_message, rls_username, conversation_history = [])
    if cross_user_reference?(user_message, rls_username)
      return {
        'mode' => 'answer',
        'answer' => "I can only answer questions for your signed-in identity (#{rls_username}). I cannot provide data for another user."
      }
    end

    schema = load_schema
    rls = Settings.rls_config
    fabric_rules = Settings.fabric_agent_instructions

    prompt = <<~PROMPT
      You are a Power BI DAX assistant.

      Goal:
      - If the user asks for dataset-backed analytics, return DAX in mode=dax.
      - If the user asks conversational or unsupported questions, return mode=answer.

      Rules for mode=dax:
      - Output a valid DAX query beginning with EVALUATE.
      - Prefer SUMMARIZECOLUMNS for grouped answers.
      - Always constrain by the current user using CALCULATETABLE with identity filter.
      - Use this identity filter when enabled:
        '#{rls['identity_table']}'[#{rls['identity_column']}] = "#{escape_dax_string(rls_username.to_s)}"
      - Use only tables/columns/measures from the schema.

      CRITICAL — Measures vs Columns:
      - The schema lists each table's "measures" and "columns" separately.
      - ONLY reference a measure as [MeasureName] if it appears in that table's "measures" array
        in the schema. Do NOT invent measure names that are not in the schema.
      - Measures must be referenced as [MeasureName] with NO table prefix and NO aggregation wrapper.
      - Columns (listed under "columns") are referenced as 'TableName'[ColumnName] and
        MUST be aggregated with SUM/MAX/MIN/COUNT etc. when used as named expressions.
        Correct column usage:   "Hours", SUM('Fact_AllHours'[Hours])
        Wrong (column as measure): "Hours", [Hours]
        Wrong (column without aggregation): "Hours", 'Fact_AllHours'[Hours]
      - Never SUM() or aggregate a true measure — measures are already aggregations.
      - When in doubt, check the schema "measures" array. If the name is not there, treat it as a
        column and use SUM() or another appropriate aggregation.

      - When asked about hours, utilization, or expense types: ALWAYS group by BOTH
        'Dim_User'[Username] AND 'Dim_Task'[Expense Type] in SUMMARIZECOLUMNS.
        Prefer schema-discovered measures only if they are present in a table's "measures" array.
        If those measures are not present, use column-based aggregation from available columns.
        Safe fallback pattern (column-based) for hours by expense type:
          EVALUATE
          SUMMARIZECOLUMNS(
              'Dim_User'[Username],
              'Dim_Task'[Expense Type],
              FILTER(ALL('Dim_User'), 'Dim_User'[Username] = "#{escape_dax_string(rls_username.to_s)}"),
              "Hours", SUM('Fact_AllHours'[Hours])
          )
        If utilization data is requested and a utilization measure is not present in schema measures,
        return the hours breakdown and mention utilization measure is unavailable in this model.
      - NEVER wrap SUMMARIZECOLUMNS in CALCULATETABLE — this is invalid DAX and causes runtime errors.
      - Apply row-level identity filters using FILTER(ALL('Table'), 'Table'[Col] = "value") placed
        INSIDE SUMMARIZECOLUMNS, before the named measure expressions.
      - Never return only a single total — always break down by Expense Type.
      - Always include the date range that covers the data (use 'Date'[Date] bounds if filtering).
      - If the user asks for projects and tasks, include both project and task fields in the result
        (for example 'Dim_Project'[ProjectName] and 'Dim_Task'[Taskname]) instead of returning only
        project-level rows.

      Rules for mode=answer:
      - If the user sends a simple greeting (for example: hi, hello, hey), respond conversationally with exactly: "Hello! How can I help you today?"
      - For other non-data questions, keep the response short and helpful.

      Fabric-style business instructions to enforce:
      #{fabric_rules}

      Dataset schema (JSON):
      #{schema.to_json}

      RLS config (JSON):
      #{rls.to_json}

      Return ONLY strict JSON in one of these shapes:
      {"mode":"dax","dax":"EVALUATE ..."}
      {"mode":"answer","answer":"..."}
    PROMPT

    messages = build_messages(prompt, user_message, conversation_history)
    raw = azure_chat_completion(messages)
    parsed = parse_llm_json(raw)

    mode = parsed['mode'].to_s
    if mode == 'dax' && !parsed['dax'].to_s.strip.empty?
      { 'mode' => 'dax', 'dax' => parsed['dax'].to_s.strip }
    else
      answer = parsed['answer'].to_s.strip
      answer = 'I can help with data questions from your Power BI model. Please rephrase your request.' if answer.empty?
      { 'mode' => 'answer', 'answer' => answer }
    end
  rescue => e
    logger.error "generate_dax failed: #{e.class} - #{e.message}"
    raise e
  end

  def summarize(user_message, dax, results, conversation_history = [])
    rows = results.is_a?(Array) ? results : []
    if Settings.enable_project_shortcuts
      project_list_answer = summarize_as_project_list(user_message, rows)
      return project_list_answer unless project_list_answer.nil?
    end

    preview = rows.first(Settings.summary_row_limit)
    fabric_rules = Settings.fabric_agent_instructions

    prompt = <<~PROMPT
      You are a data analyst assistant presenting Power BI query results.

      Formatting rules:
      - Always state the user's name/email and the date range covered by the data at the top.
      - When results contain 'Expense Type' or similar category breakdowns, present them as a
        Markdown table with User as the first column and each unique Expense Type as a column header.
        Fill each cell with the corresponding Actual Hours value (blank if none).
      - After the table, add a bullet list showing Utilization % (to 2 decimal places) for each
        Expense Type that has a non-null, non-zero Util % value.
      - If results are empty, explain that no data was found for the requested scope.
      - Never mention row counts, column counts, query metadata, or data preview wording.
      - Do not invent values not present in the data.
      - Close with a friendly offer to provide a different date range or more detail.

      Fabric-style business instructions to also enforce:
      #{fabric_rules}
    PROMPT

    user_payload = {
      question: user_message,
      dax: dax,
      rows_preview: preview
    }

    messages = []
    messages << { role: 'system', content: prompt }
    conversation_history.last(8).each do |item|
      role = map_role(item['role'])
      content = item['content'].to_s
      next if content.empty?

      messages << { role: role, content: content }
    end
    messages << { role: 'user', content: "Summarize this result set: #{user_payload.to_json}" }

    azure_chat_completion(messages)
  rescue => e
    logger.error "summarize failed: #{e.class} - #{e.message}"
    raise e
  end

  private

  def load_schema
    path = File.join(File.dirname(__FILE__), 'sample_report', 'schema.json')
    if File.exist?(path)
      JSON.parse(File.read(path))
    else
      { 'tables' => [] }
    end
  rescue => e
    logger.warn "Failed loading schema.json: #{e.class} - #{e.message}"
    { 'tables' => [] }
  end

  def build_messages(system_prompt, user_message, history)
    messages = []
    messages << { role: 'system', content: system_prompt }
    history.last(8).each do |item|
      role = map_role(item['role'])
      content = item['content'].to_s
      next if content.empty?

      messages << { role: role, content: content }
    end
    messages << { role: 'user', content: user_message.to_s }
    messages
  end

  def map_role(role)
    case role.to_s
    when 'assistant', 'bot'
      'assistant'
    when 'system'
      'system'
    else
      'user'
    end
  end

  def azure_chat_completion(messages)
    endpoint = Settings.azure_openai_endpoint.to_s.chomp('/')
    deployment = Settings.azure_openai_deployment
    api_version = Settings.azure_openai_api_version

    raise 'AZURE_OPENAI_ENDPOINT is not configured' if endpoint.empty?
    raise 'AZURE_OPENAI_DEPLOYMENT is not configured' if deployment.to_s.strip.empty?

    url = "#{endpoint}/openai/deployments/#{deployment}/chat/completions?api-version=#{api_version}"

    headers = {
      content_type: :json,
      accept: :json
    }

    api_key = Settings.azure_openai_api_key.to_s
    if api_key.empty?
      token = Settings.azure_openai_bearer_token
      raise 'AZURE_OPENAI_API_KEY is missing and no Azure CLI token is available' if token.to_s.strip.empty?

      headers[:Authorization] = "Bearer #{token}"
    else
      headers['api-key'] = api_key
    end

    body = {
      messages: messages,
      temperature: 0.2,
      max_tokens: Settings.azure_openai_max_tokens
    }

    response = RestClient.post(url, body.to_json, headers)
    parsed = JSON.parse(response.body)
    content = parsed.dig('choices', 0, 'message', 'content').to_s
    raise 'Empty response from Azure OpenAI' if content.strip.empty?

    content
  rescue RestClient::ExceptionWithResponse => e
    logger.error "Azure OpenAI error #{e.response.code}: #{e.response.body[0..600]}"
    raise "Azure OpenAI request failed (#{e.response.code})"
  end

  def parse_llm_json(text)
    begin
      return JSON.parse(text)
    rescue JSON::ParserError
      # Best-effort recovery when the model wraps JSON in prose.
      start_idx = text.index('{')
      end_idx = text.rindex('}')
      raise "Invalid JSON response from model: #{text[0..200]}" if start_idx.nil? || end_idx.nil? || end_idx <= start_idx

      JSON.parse(text[start_idx..end_idx])
    end
  end

  def escape_dax_string(value)
    value.gsub('"', '""')
  end

  def summarize_as_project_list(user_message, rows)
    return nil unless project_list_question?(user_message)

    project_column = detect_project_column(rows)
    return nil if project_column.nil?

    projects = rows.map { |row| row[project_column] }
                   .compact
                   .map { |value| value.to_s.strip }
                   .reject(&:empty?)
                   .uniq
                   .sort

    return 'I could not find any projects for your current access scope.' if projects.empty?

    lines = ['Here are your projects:']
    projects.each do |project|
      lines << "- #{project}"
    end
    lines.join("\n")
  end

  def detect_project_column(rows)
    sample = rows.find { |row| row.is_a?(Hash) }
    return nil if sample.nil?

    sample.keys.find { |key| key.to_s.downcase.include?('project') }
  end

  def project_list_question?(user_message)
    text = user_message.to_s.downcase
    asks_project = text.include?('project')
    asks_task = text.include?('task') || text.include?('tasks')

    # Only use the lightweight project list formatter when the user is
    # explicitly asking for projects, not when they ask for projects and tasks.
    asks_project && !asks_task
  end

  def cross_user_reference?(user_message, rls_username)
    text = user_message.to_s.downcase
    current_identity = rls_username.to_s.downcase.strip
    return false if text.empty? || current_identity.empty?

    referenced_emails = text.scan(/\b[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}\b/)
    return true if referenced_emails.any? { |email| email != current_identity }

    Settings.demo_users.each do |display_name, email|
      other_email = email.to_s.downcase.strip
      other_name = display_name.to_s.downcase.strip
      next if other_email.empty?
      next if other_email == current_identity

      return true if text.include?(other_email)
      return true if !other_name.empty? && text.include?(other_name)
    end

    false
  end
end
