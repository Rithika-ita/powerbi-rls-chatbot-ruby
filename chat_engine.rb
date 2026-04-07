require 'json'
require 'rest-client'
require_relative 'config'
require_relative 'powerbi_service'

module ChatEngine
  extend self

  def logger
    Settings.logger
  end

  # ── Azure OpenAI ────────────────────────────────────────────────────────────

  def call_openai(messages, tools: nil)
    endpoint   = Settings.azure_openai_endpoint&.chomp("/")
    deployment = Settings.azure_openai_deployment
    api_version = Settings.azure_openai_api_version
    api_key    = Settings.azure_openai_api_key

    raise "AZURE_OPENAI_ENDPOINT is not configured." if endpoint.nil? || endpoint.strip.empty?
    raise "AZURE_OPENAI_DEPLOYMENT is not configured." if deployment.nil? || deployment.strip.empty?

    url = "#{endpoint}/openai/deployments/#{deployment}/chat/completions?api-version=#{api_version}"

    headers = { content_type: :json, accept: :json }
    if api_key.to_s.strip.empty?
      token = PowerBIService.get_azcli_token
      headers[:Authorization] = "Bearer #{token}"
    else
      headers["api-key"] = api_key
    end

    body = {
      messages: messages,
      temperature: 0.1,
      max_tokens: 2048
    }
    body[:tools] = tools if tools
    body[:tool_choice] = "auto" if tools

    logger.info "Calling Azure OpenAI: #{url}"
    response = RestClient.post(url, body.to_json, headers)
    JSON.parse(response.body)
  rescue RestClient::ExceptionWithResponse => e
    logger.error "Azure OpenAI call failed #{e.response.code}: #{e.response.body[0..500]}"
    raise "Azure OpenAI error (#{e.response.code}): #{e.response.body}"
  end

  # ── Function Calling Tools ──────────────────────────────────────────────────

  DAX_TOOL = {
    type: "function",
    function: {
      name: "execute_dax_query",
      description: "Execute a DAX query against the Power BI dataset and return rows of data. " \
                   "Use this whenever the user asks a data question. The query MUST start with EVALUATE.",
      parameters: {
        type: "object",
        properties: {
          dax_query: {
            type: "string",
            description: "The DAX query to execute. Must start with EVALUATE."
          }
        },
        required: ["dax_query"]
      }
    }
  }.freeze

  def build_system_prompt(schema, rls_config, rls_username)
    schema_text     = JSON.pretty_generate(schema)
    rls_desc        = rls_config["description"] || ""
    identity_table  = rls_config["identity_table"] || ""
    identity_column = rls_config["identity_column"] || ""
    filter_table    = rls_config["filter_table"] || ""
    filter_column   = rls_config["filter_column"] || ""

    <<~PROMPT
      You are a Power BI data assistant. Help users explore their data by generating
      and executing DAX queries using the execute_dax_query tool.

      Dataset schema:
      #{schema_text}

      RLS context: #{rls_desc}
      Current user: "#{rls_username}"
      Identity: '#{identity_table}'[#{identity_column}]
      The server applies an RLS filter on '#{filter_table}'[#{filter_column}] via TREATAS —
      you must NEVER add TREATAS or CALCULATETABLE for '#{filter_table}'[#{filter_column}].

      CONCEPT GLOSSARY — what each concept means in this dataset:
      ┌─────────────────────────────────────┬────────────────────────────────────────────────────────────────┐
      │ User concept                        │ Table / columns to use                                         │
      ├─────────────────────────────────────┼────────────────────────────────────────────────────────────────┤
      │ "actual hours" / "my hours"         │ Fact_Pivoted_Hours — see category columns below                │
      │ "hours by category" / "breakdown"   │ Fact_Pivoted_Hours — same                                      │
      │ individual time entries / time logs │ Fact_AllHours[Hours] — raw rows                                │
      │ project assignments / allocations   │ Fact_Assignment                                                │
      │ dates / time frame / periods        │ 'Date'[Date] — master date table                               │
      │ fiscal year / quarter               │ 'Date'[FiscalYear], [FiscalQuarter], [FiscalYearQuarter]       │
      └─────────────────────────────────────┴────────────────────────────────────────────────────────────────┘

      DATE & TIME FRAME RULES:
      - The 'Date' table is the master date dimension. Key columns: [Date], [FiscalYear],
        [FiscalQuarter], [FiscalYearQuarter], [MonthName], [Year], [IsCurrentFiscalYear].
      - Fact_Pivoted_Hours has [EntryDate]; Fact_AllHours has [EntryDate].
      - When the user asks "what time frame" or "what period" — ALWAYS query the actual data
        to find the date range. NEVER guess. Use this pattern:
        EVALUATE
        ROW("Start Date", MIN('Fact_Pivoted_Hours'[EntryDate]), "End Date", MAX('Fact_Pivoted_Hours'[EntryDate]))
      - When reporting results, ALWAYS state the date range the data covers (e.g. "from June 1, 2021
        to December 31, 2026"). Query for it if you don't already know it.
      - Filter by date when the user says "this year", "last quarter", "FY2025", etc.
        Example: KEEPFILTERS('Date'[FiscalYear] = 2025)

      Fact_Pivoted_Hours CATEGORY COLUMNS (always include all of these for an hours question):
        [Capitalizable Cost], [Chargeable Program Cost], [Enterprise],
        [Non-Chargeable Program Cost], [Professional Development], [Time Off (-)], [Time Off (=)]
      Join to Dim_User via the relationship on UserId to get '#{identity_table}'[#{identity_column}] and [Name].

      "my" vs "all" data:
      - "my data/hours" → filter KEEPFILTERS('#{identity_table}'[#{identity_column}] = "#{rls_username}")
      - "all/everyone/team" → no user filter (RLS restricts by #{filter_column} automatically)

      DAX rules:
      - Always start with EVALUATE
      - Use single-quoted table names: 'TableName'[ColumnName]
      - Use SUMMARIZECOLUMNS for all aggregations
      - In SUMMARIZECOLUMNS: only group-by columns and "Name", expression pairs — NEVER boolean predicates
      - Filters go in CALCULATETABLE(..., KEEPFILTERS(...))
      - NEVER use Fact_AllHours to answer questions about "actual hours" or an "hours breakdown" — use Fact_Pivoted_Hours

      EXAMPLE — "what are my actual hours":
      EVALUATE
      CALCULATETABLE(
          SUMMARIZECOLUMNS(
              '#{identity_table}'[#{identity_column}],
              'Dim_User'[Name],
              "Capitalizable Cost", SUM('Fact_Pivoted_Hours'[Capitalizable Cost]),
              "Chargeable Program Cost", SUM('Fact_Pivoted_Hours'[Chargeable Program Cost]),
              "Enterprise", SUM('Fact_Pivoted_Hours'[Enterprise]),
              "Non-Chargeable Program Cost", SUM('Fact_Pivoted_Hours'[Non-Chargeable Program Cost]),
              "Professional Development", SUM('Fact_Pivoted_Hours'[Professional Development]),
              "Time Off (-)", SUM('Fact_Pivoted_Hours'[Time Off (-)]),
              "Time Off (=)", SUM('Fact_Pivoted_Hours'[Time Off (=)])
          ),
          KEEPFILTERS('#{identity_table}'[#{identity_column}] = "#{rls_username}")
      )

      Response rules:
      - NEVER include DAX code, code blocks, or backticks in your text reply.
      - For greetings or non-data questions, respond directly without calling the tool.
      - For data questions, call execute_dax_query, then summarise results in plain language.
      - ALWAYS state the date range the data covers. If you haven't already queried for it,
        make a second tool call to get MIN/MAX dates before writing your final answer.
      - Write 2-4 short bullet insights when multiple metric columns are returned.
      - Do NOT reproduce a table in text — the UI renders the raw data rows automatically.
      - Present single numbers in a clear sentence with one contextual observation.
      - Use friendly column names (e.g. "Chargeable Program Cost" not "Fact_Pivoted_Hours[Chargeable Program Cost]").
      - Be concise and conversational. Never mention DAX, SQL, or technical details.
    PROMPT
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # If the model generated a naive Fact_AllHours SUM, upgrade it to the full
  # Fact_Pivoted_Hours category breakdown that matches the Power BI report view.
  def upgrade_hours_query(dax_query, rls_username, rls_config)
    identity_table  = rls_config["identity_table"] || "Dim_User"
    identity_column = rls_config["identity_column"] || "Username"

    # Only rewrite simple hours-sum queries against Fact_AllHours
    is_hours_sum = dax_query =~ /Fact_AllHours/i &&
                   dax_query =~ /SUM\s*\(\s*'?Fact_AllHours'?\s*\[\s*Hours\s*\]/i

    return dax_query unless is_hours_sum

    logger.info "Upgrading Fact_AllHours sum to Fact_Pivoted_Hours category breakdown"

    # Build user filter clause only if username is present
    user_filter = rls_username.to_s.strip.empty? ? "" :
      ",\n            KEEPFILTERS('#{identity_table}'[#{identity_column}] = \"#{rls_username}\")"

    <<~DAX.strip
      EVALUATE
      CALCULATETABLE(
          SUMMARIZECOLUMNS(
              '#{identity_table}'[#{identity_column}],
              'Dim_User'[Name],
              "Capitalizable Cost", SUM('Fact_Pivoted_Hours'[Capitalizable Cost]),
              "Chargeable Program Cost", SUM('Fact_Pivoted_Hours'[Chargeable Program Cost]),
              "Enterprise", SUM('Fact_Pivoted_Hours'[Enterprise]),
              "Non-Chargeable Program Cost", SUM('Fact_Pivoted_Hours'[Non-Chargeable Program Cost]),
              "Professional Development", SUM('Fact_Pivoted_Hours'[Professional Development]),
              "Time Off (-)", SUM('Fact_Pivoted_Hours'[Time Off (-)]),
              "Time Off (=)", SUM('Fact_Pivoted_Hours'[Time Off (=)])
          )#{user_filter}
      )
    DAX
  end

  # Remove markdown code fences (``` ... ```) and any HTML code divs the model
  # may accidentally include in its plain-language reply.
  def strip_code_blocks(text)
    return text if text.nil? || text.empty?
    # Remove fenced code blocks
    cleaned = text.gsub(/```.*?```/m, '')
    # Strip every HTML tag (opening, closing, self-closing)
    cleaned = cleaned.gsub(/<\/?[a-z][^>]*>/i, '')
    # Remove "-- Generated DAX" and everything after it
    cleaned = cleaned.sub(/--\s*Generated\s+DAX.*/mi, '')
    # Remove any remaining EVALUATE ... block at the end
    cleaned = cleaned.sub(/\bEVALUATE\b.*/mi, '')
    # Collapse blank lines
    cleaned = cleaned.gsub(/\n{3,}/, "\n\n")
    cleaned.strip
  end

  # ── Main Entry Point ────────────────────────────────────────────────────────

  def chat(user_message, rls_username, conversation_history = [])
    schema     = PowerBIService.get_dataset_schema
    rls_config = Settings.rls_config
    chat_with_azure_openai(user_message, rls_username, conversation_history, schema, rls_config)
  rescue => e
    logger.error "ChatEngine error: #{e.class} - #{e.message}"
    raise e
  end

  def chat_with_azure_openai(user_message, rls_username, conversation_history, schema, rls_config)
    logger.info "Using Azure OpenAI (function calling) for #{rls_username}"

    system_prompt = build_system_prompt(schema, rls_config, rls_username)
    messages = [{ role: "system", content: system_prompt }]

    # Include recent conversation history for context
    # Strip any code blocks from assistant history so the model doesn't repeat the pattern
    conversation_history.last(6).each do |turn|
      content = turn["content"] || ""
      content = strip_code_blocks(content) if turn["role"] == "assistant"
      messages << { role: turn["role"], content: content }
    end
    messages << { role: "user", content: user_message }

    tools = [DAX_TOOL]
    last_dax  = nil
    last_data = nil
    max_rounds = 3  # safety limit to prevent infinite loops

    max_rounds.times do |round|
      result  = call_openai(messages, tools: tools)
      choice  = result.dig("choices", 0) || {}
      msg     = choice["message"] || {}

      # If the model wants to call a tool
      if msg["tool_calls"] && !msg["tool_calls"].empty?
        # Append the assistant message (with tool_calls) to conversation
        messages << msg

        msg["tool_calls"].each do |tool_call|
          fn_name = tool_call.dig("function", "name")
          fn_args = JSON.parse(tool_call.dig("function", "arguments") || "{}")
          call_id = tool_call["id"]

          if fn_name == "execute_dax_query"
            dax_query = fn_args["dax_query"] || ""
            dax_query = upgrade_hours_query(dax_query, rls_username, rls_config)
            logger.info "Function call: execute_dax_query (round #{round + 1})\n#{dax_query}"
            last_dax = dax_query

            begin
              rows = PowerBIService.execute_dax(dax_query, rls_username: rls_username)
              last_data = rows
              logger.info "DAX returned #{rows.size} rows for #{rls_username}"

              # Truncate to 100 rows to avoid token overflow
              sample = rows.first(100)
              tool_result = sample.empty? ?
                "No data found for this query." :
                JSON.generate(sample)
            rescue => e
              logger.error "DAX execution failed: #{e.message}"
              tool_result = "Error executing query: #{e.message}"
              last_data = nil
            end
          else
            tool_result = "Unknown function: #{fn_name}"
          end

          messages << {
            role: "tool",
            tool_call_id: call_id,
            content: tool_result
          }
        end

        # Continue the loop — OpenAI will now summarise the results
        next
      end

      # No tool call — the model produced a final text response
      answer = msg["content"] || "I was unable to process your request."
      answer = strip_code_blocks(answer)
      logger.info "Final answer for #{rls_username}: #{answer[0..200]}"

      return {
        "answer" => answer,
        "data"   => last_data
      }
    end

    # If we exhausted rounds without a final answer
    {
      "answer" => "I was unable to complete the query. Please try rephrasing your question.",
      "data"   => last_data
    }
  rescue => e
    logger.error "chat_with_azure_openai failed: #{e.class} - #{e.message}"
    raise e
  end
end
