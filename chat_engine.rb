require 'json'
require 'openai'
require_relative 'config'
require_relative 'powerbi_service'

module ChatEngine
  extend self

  def logger
    Settings.logger
  end

  def openai_client
    @openai_client ||= OpenAI::Client.new(
      access_token: Settings.azure_openai_api_key,
      uri_base: Settings.azure_openai_endpoint,
      api_type: :azure,
      api_version: Settings.azure_openai_api_version
    )
  end

  SYSTEM_PROMPT_BASE = <<~PROMPT
    You are a helpful data analyst chatbot. You answer questions about business data
    stored in a Power BI semantic model (dataset).

    ## Dataset Schema
    %{schema_json}

    %{rls_context}

    ## Rules
    1. When the user asks a data question, generate a **single valid DAX query**
       wrapped in a ```dax code fence.
    2. Use EVALUATE to return a table result.  Do NOT use DEFINE unless needed for
       variables.
    3. Only reference tables, columns, and measures from the schema above.
    4. %{rls_filter_rule}
    5. If the user asks something unrelated to the data, respond conversationally
       WITHOUT generating DAX.
    6. Keep DAX concise and correct.  Prefer SUMMARIZECOLUMNS for aggregations.
    7. After receiving the query results, provide a clear, concise natural-language
       answer.  If the results are tabular, format them as a Markdown table.
    8. If a query returns no data, say so and suggest the user may not have access
       to that slice of data due to their role.
  PROMPT

  def build_system_prompt(schema_json, rls_username, user_filter_values)
    rls = Settings.rls_config

    if rls["enabled"] && !user_filter_values.empty?
      ft = rls["filter_table"]
      fc = rls["filter_column"]
      desc = rls["description"] || ""
      values_str = user_filter_values.join(", ")
      rls_context = <<~CONTEXT
        ## Current User RLS Context
        The current user (#{rls_username}) has access to these #{ft}.#{fc} values: #{values_str}
        All DAX query results will be automatically filtered to these values.
        #{desc}
      CONTEXT
      rls_filter_rule = "Do NOT add #{ft}/#{fc} filters yourself — the system automatically applies RLS filters via CALCULATETABLE + TREATAS."
    elsif rls["enabled"]
      rls_context = <<~CONTEXT
        ## Current User RLS Context
        The current user (#{rls_username}) has no accessible data in this model.
      CONTEXT
      rls_filter_rule = "The user has no data access. Inform them politely."
    else
      rls_context = "## Note\nNo Row-Level Security is configured for this dataset."
      rls_filter_rule = "No RLS filters are applied. Queries return all data."
    end

    SYSTEM_PROMPT_BASE % {
      schema_json: schema_json,
      rls_context: rls_context,
      rls_filter_rule: rls_filter_rule
    }
  end

  def extract_dax(text)
    if text =~ /```dax\s*\n(.*?)\s*```/mi
      $1.strip
    elsif text =~ /(EVALUATE\b.+)/mi
      $1.strip
    else
      nil
    end
  end

  def chat(user_message, rls_username, conversation_history = [])
    schema = PowerBIService.get_dataset_schema
    rls = Settings.rls_config
    user_filter_values = []
    
    if rls["enabled"]
      token = PowerBIService.get_dax_token
      user_filter_values = PowerBIService.get_user_filter_values(rls_username, token)
    end

    system_msg = build_system_prompt(
      JSON.pretty_generate(schema),
      rls_username,
      user_filter_values
    )

    messages = [{ role: "system", content: system_msg }]
    messages += conversation_history.last(10).map { |m| { role: m["role"], content: m["content"] } }
    messages << { role: "user", content: user_message }

    # Step 1: Generate DAX
    response = openai_client.chat(
      parameters: {
        model: Settings.azure_openai_deployment,
        messages: messages,
        temperature: 0.1,
        max_tokens: 1024
      }
    )

    assistant_text = response.dig("choices", 0, "message", "content") || ""
    dax_query = extract_dax(assistant_text)

    if dax_query.nil?
      return {
        "answer" => assistant_text,
        "dax" => nil,
        "data" => nil
      }
    end

    # Step 2: Execute DAX
    begin
      rows = PowerBIService.execute_dax(dax_query, rls_username: rls_username)
    rescue => e
      logger.error "DAX execution failed: #{e}"
      return {
        "answer" => "I generated a query but it failed to execute: #{e.message}",
        "dax" => dax_query,
        "data" => nil
      }
    end

    # Step 3: Summarize
    result_text = JSON.pretty_generate(rows.first(200))
    messages << { role: "assistant", content: assistant_text }
    messages << {
      role: "user",
      content: "Here are the query results (JSON). Summarise them in natural language for the user. If tabular, show a Markdown table.\n\n#{result_text}"
    }

    response2 = openai_client.chat(
      parameters: {
        model: Settings.azure_openai_deployment,
        messages: messages,
        temperature: 0.3,
        max_tokens: 1024
      }
    )

    final_answer = response2.dig("choices", 0, "message", "content") || ""

    {
      "answer" => final_answer,
      "dax" => dax_query,
      "data" => rows
    }
  end
end
