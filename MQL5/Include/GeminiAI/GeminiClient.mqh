//+------------------------------------------------------------------+
//|                                                GeminiClient.mqh  |
//|  Wraps the Google Gemini "generateContent" REST endpoint:        |
//|   - builds the natural-language + JSON-data prompt                |
//|   - forces strict JSON output via responseSchema                  |
//|   - parses the reply into strongly-typed decision structs         |
//+------------------------------------------------------------------+
#property strict
#include <GeminiAI/Json.mqh>
#include <GeminiAI/Conversation.mqh>

//--- decision returned for a NEW entry (strategy signal -> trade idea)
struct SEntryDecision
  {
   bool     valid;            // false if the call failed / response unusable
   string   decisionMode;     // ENTER_NOW | WATCH | NONE
   string   action;           // BUY | SELL | NONE
   string   orderType;        // MARKET | LIMIT | STOP (used when decisionMode==ENTER_NOW)
   double   entryPrice;       // required for LIMIT / STOP
   double   stopLoss;
   double   takeProfit;
   int      expiryMinutes;    // pending order / watch-plan expiry, 0 = use EA default
   double   confidence;       // 0..1
   string   reason;
   //--- WATCH-plan fields (used when decisionMode==WATCH): the EA watches price
   //--- in real time and enters when it reaches the zone, cancels on invalidation.
   double   watchEntryLow;    // entry zone lower bound
   double   watchEntryHigh;   // entry zone upper bound
   double   invalidatePrice;  // cancel plan if price passes this before entering
  };

//--- decision returned for MANAGING an already-open position
struct SManageDecision
  {
   bool     valid;
   string   action;                 // HOLD | MOVE_SL | MOVE_TP | TRAIL_SL | CLOSE | CLOSE_PARTIAL
   double   newSL;
   double   newTP;
   double   trailDistancePoints;
   double   closeFraction;          // 0..1, used by CLOSE_PARTIAL
   string   reason;
  };

class CGeminiClient
  {
private:
   string   m_apiKey;
   string   m_model;
   int      m_timeoutMs;
   double   m_temperature;

   string   EntrySchema() const
     {
      return "{\"type\":\"OBJECT\",\"properties\":{"
             "\"decision_mode\":{\"type\":\"STRING\",\"enum\":[\"ENTER_NOW\",\"WATCH\",\"NONE\"]},"
             "\"action\":{\"type\":\"STRING\",\"enum\":[\"BUY\",\"SELL\",\"NONE\"]},"
             "\"order_type\":{\"type\":\"STRING\",\"enum\":[\"MARKET\",\"LIMIT\",\"STOP\"]},"
             "\"entry_price\":{\"type\":\"NUMBER\"},"
             "\"watch_entry_low\":{\"type\":\"NUMBER\"},"
             "\"watch_entry_high\":{\"type\":\"NUMBER\"},"
             "\"invalidate_price\":{\"type\":\"NUMBER\"},"
             "\"stop_loss\":{\"type\":\"NUMBER\"},"
             "\"take_profit\":{\"type\":\"NUMBER\"},"
             "\"expiry_minutes\":{\"type\":\"INTEGER\"},"
             "\"confidence\":{\"type\":\"NUMBER\"},"
             "\"reason\":{\"type\":\"STRING\"}},"
             "\"required\":[\"decision_mode\",\"action\",\"stop_loss\",\"take_profit\",\"confidence\",\"reason\"]}";
     }

   string   ManageSchema() const
     {
      return "{\"type\":\"OBJECT\",\"properties\":{"
             "\"action\":{\"type\":\"STRING\",\"enum\":[\"HOLD\",\"MOVE_SL\",\"MOVE_TP\",\"TRAIL_SL\",\"CLOSE\",\"CLOSE_PARTIAL\"]},"
             "\"new_sl\":{\"type\":\"NUMBER\"},"
             "\"new_tp\":{\"type\":\"NUMBER\"},"
             "\"trail_distance_points\":{\"type\":\"NUMBER\"},"
             "\"close_fraction\":{\"type\":\"NUMBER\"},"
             "\"reason\":{\"type\":\"STRING\"}},"
             "\"required\":[\"action\",\"reason\"]}";
     }

   //--- low level HTTP call, returns the raw "text" field produced by the model.
   //--- if convo is non-NULL, its stored history is prepended so the model has
   //--- continuity across calls (the current prompt becomes the latest user turn).
   bool     Call(const string prompt, const string schemaJson, CConversation *convo, string &outText, string &outError)
     {
      string url = "https://generativelanguage.googleapis.com/v1beta/models/" + m_model + ":generateContent";
      string headers = "Content-Type: application/json\r\nx-goog-api-key: " + m_apiKey + "\r\n";
      string contents = (convo != NULL)
                        ? convo.BuildContents(prompt)
                        : "[{\"role\":\"user\",\"parts\":[{\"text\":\"" + JsonEscape(prompt) + "\"}]}]";
      string body = "{\"contents\":" + contents +
                    ",\"generationConfig\":{\"temperature\":" + DoubleToString(m_temperature, 2) +
                    ",\"responseMimeType\":\"application/json\",\"responseSchema\":" + schemaJson + "}}";

      char post[];
      int total = StringToCharArray(body, post, 0, -1, CP_UTF8);
      ArrayResize(post, total - 1); // drop the terminating NUL added by StringToCharArray

      char result[];
      string resultHeaders;
      ResetLastError();
      int status = WebRequest("POST", url, headers, m_timeoutMs, post, result, resultHeaders);
      if(status == -1)
        {
         outError = StringFormat("WebRequest error %d. Add '%s' to Tools > Options > Expert Advisors > Allow WebRequest for listed URL.",
                                  GetLastError(), "https://generativelanguage.googleapis.com");
         return false;
        }

      string responseText = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      if(status != 200)
        {
         outError = StringFormat("Gemini HTTP %d: %s", status, responseText);
         return false;
        }

      CJsonValue *root = CJsonValue::Parse(responseText);
      bool ok = false;
      if(root != NULL && root.Type() == JSON_OBJECT)
        {
         CJsonValue *candidates = root.Get("candidates");
         if(candidates != NULL && candidates.Type() == JSON_ARRAY && candidates.Size() > 0)
           {
            CJsonValue *content = candidates.At(0).Get("content");
            CJsonValue *parts = (content != NULL) ? content.Get("parts") : NULL;
            if(parts != NULL && parts.Type() == JSON_ARRAY && parts.Size() > 0)
              {
               outText = parts.At(0).GetString("text");
               ok = (StringLen(outText) > 0);
              }
           }
         if(!ok)
           {
            CJsonValue *feedback = root.Get("promptFeedback");
            string blockReason = (feedback != NULL) ? feedback.GetString("blockReason") : "";
            outError = "Gemini returned no usable candidate" + (StringLen(blockReason) > 0 ? (" (blocked: " + blockReason + ")") : "") + ": " + responseText;
           }
        }
      else
        {
         outError = "Failed to parse Gemini response JSON: " + responseText;
        }
      if(root != NULL)
         delete root;
      return ok;
     }

public:
   void     Init(const string apiKey, const string model, const int timeoutMs, const double temperature)
     {
      m_apiKey = apiKey;
      m_model = model;
      m_timeoutMs = timeoutMs;
      m_temperature = temperature;
     }

   //--- ask Gemini for a NEW trade decision based on a strategy's market snapshot.
   //--- convo (optional) gives the strategy memory of its recent decisions.
   //--- allowWatch enables the human-like "WATCH" mode (define an entry zone and
   //--- let the EA wait in real time) in addition to immediate ENTER_NOW.
   bool     RequestEntryDecision(const int strategyId, const string strategyName, const string conditionDesc,
                                 const string marketSnapshotJson, SEntryDecision &out, CConversation *convo = NULL,
                                 const bool allowWatch = true)
     {
      out.valid = false;
      string memoryNote = (convo != NULL && convo.Size() > 0)
                          ? "The earlier turns in this conversation are your OWN recent decisions for this same strategy module; "
                            "stay consistent with them unless the new data clearly warrants a different call.\n"
                          : "";
      string modeNote = allowWatch
         ? "Choose decision_mode like a human trader:\n"
           "- ENTER_NOW: the setup is ready right now -> also set order_type (MARKET, or LIMIT/STOP with entry_price).\n"
           "- WATCH: the idea is good but the ideal entry is at a price the market has NOT reached yet -> instead of "
           "entering, define an entry zone [watch_entry_low, watch_entry_high] and an invalidate_price. The EA will then "
           "watch price in REAL TIME (every tick) and enter with a market order the moment price reaches the zone, or "
           "cancel the plan if price passes invalidate_price first, if the higher timeframe trend flips against the "
           "trade, or after expiry_minutes. For a BUY, invalidate_price must be BELOW the zone; for a SELL, ABOVE it.\n"
           "- NONE: no trade.\n"
         : "Set decision_mode to ENTER_NOW (with order_type) to trade now, or NONE to skip. Do not use WATCH.\n";
      string prompt =
         "You are the decision engine of an MT5 trading strategy module (id=" + IntegerToString(strategyId) +
         ", name=\"" + strategyName + "\").\n" + memoryNote +
         "The module's gating condition just fired: " + conditionDesc + "\n" +
         "The market data JSON below is MULTI-TIMEFRAME: \"ohlc\"/\"common_indicators\" describe the strategy's " +
         "working timeframe (\"timeframe\"), and \"htf_ohlc\"/\"htf_indicators\" describe a higher timeframe " +
         "(\"higher_timeframe\") for trend/context confirmation. You MUST cross-check both timeframes before " +
         "deciding: only take the trade if the higher timeframe context does not contradict the working-timeframe " +
         "setup. Be conservative: if the setup is not clearly favorable on both timeframes, return decision_mode=NONE.\n" +
         modeNote +
         "For any BUY or SELL you MUST provide stop_loss and take_profit as absolute prices consistent with the symbol's price scale.\n" +
         "Respond using the exact JSON schema provided, no extra commentary.\n\n" +
         "MARKET_DATA_JSON:\n" + marketSnapshotJson;

      string text, err;
      if(!Call(prompt, EntrySchema(), convo, text, err))
        {
         Print("[GeminiClient] entry decision call failed: ", err);
         return false;
        }

      //--- record the exchange in this strategy's memory (compact user summary + full reply)
      if(convo != NULL)
        {
         string summary = StringFormat("[entry check] %s => (see decision)", conditionDesc);
         convo.AddExchange(summary, text);
        }

      CJsonValue *root = CJsonValue::Parse(text);
      if(root == NULL || root.Type() != JSON_OBJECT)
        {
         Print("[GeminiClient] entry decision JSON parse failed: ", text);
         if(root != NULL) delete root;
         return false;
        }

      out.decisionMode    = root.GetString("decision_mode", "ENTER_NOW");
      out.action          = root.GetString("action", "NONE");
      out.orderType       = root.GetString("order_type", "MARKET");
      out.entryPrice      = root.GetDouble("entry_price", 0.0);
      out.watchEntryLow   = root.GetDouble("watch_entry_low", 0.0);
      out.watchEntryHigh  = root.GetDouble("watch_entry_high", 0.0);
      out.invalidatePrice = root.GetDouble("invalidate_price", 0.0);
      out.stopLoss        = root.GetDouble("stop_loss", 0.0);
      out.takeProfit      = root.GetDouble("take_profit", 0.0);
      out.expiryMinutes   = (int)root.GetInt("expiry_minutes", 0);
      out.confidence      = root.GetDouble("confidence", 0.0);
      out.reason          = root.GetString("reason", "");
      if(!allowWatch && out.decisionMode == "WATCH")
         out.decisionMode = "NONE";   // watch mode disabled by config -> ignore
      out.valid           = true;
      delete root;
      return true;
     }

   //--- ask Gemini how to manage an already open position once momentum gate fires.
   //--- convo (optional) is this position's own management thread, so the model
   //--- remembers what it already did at earlier checkpoints for THIS position.
   bool     RequestManageDecision(const int strategyId, const string strategyName,
                                  const string positionSnapshotJson, SManageDecision &out, CConversation *convo = NULL)
     {
      out.valid = false;
      string memoryNote = (convo != NULL && convo.Size() > 0)
                          ? "The earlier turns in this conversation are the management decisions you ALREADY made for "
                            "THIS SAME open position at previous checkpoints; build on them (e.g. do not undo a "
                            "break-even stop you already set) instead of treating this as a fresh position.\n"
                          : "";
      string prompt =
         "You are the trade-management engine of an MT5 trading strategy module (id=" + IntegerToString(strategyId) +
         ", name=\"" + strategyName + "\").\n" + memoryNote +
         "This module has an open position that just reached its next management checkpoint - see " +
         "\"position.trigger_reason\" for why (either a profit/momentum ratchet confirmed by the Momentum indicator " +
         "in \"position.momentum14\"/\"momentum_deviation\", or the higher-timeframe EMA trend in \"position.htf_ema_fast\"" +
         "/\"htf_ema_slow\" flipping against the position). The \"market\" object is again MULTI-TIMEFRAME " +
         "(working timeframe ohlc/common_indicators plus htf_ohlc/htf_indicators for the higher timeframe) - " +
         "cross-check both before deciding.\n" +
         "Decide the best management action: HOLD, MOVE_SL, MOVE_TP, TRAIL_SL (give trail_distance_points), " +
         "CLOSE, or CLOSE_PARTIAL (give close_fraction between 0 and 1).\n" +
         "Prefer protecting profit (e.g. moving stop loss to break-even or trailing) once the position is in profit. " +
         "If the trigger reason is a higher-timeframe trend flip against the position, weigh CLOSE or CLOSE_PARTIAL " +
         "more heavily unless the working-timeframe data still strongly favors holding.\n" +
         "Respond using the exact JSON schema provided, no extra commentary.\n\n" +
         "POSITION_AND_MARKET_JSON:\n" + positionSnapshotJson;

      string text, err;
      if(!Call(prompt, ManageSchema(), convo, text, err))
        {
         Print("[GeminiClient] manage decision call failed: ", err);
         return false;
        }

      //--- record this checkpoint in the position's management thread
      if(convo != NULL)
        {
         string summary = "[manage checkpoint] (see decision)";
         convo.AddExchange(summary, text);
        }

      CJsonValue *root = CJsonValue::Parse(text);
      if(root == NULL || root.Type() != JSON_OBJECT)
        {
         Print("[GeminiClient] manage decision JSON parse failed: ", text);
         if(root != NULL) delete root;
         return false;
        }

      out.action               = root.GetString("action", "HOLD");
      out.newSL                = root.GetDouble("new_sl", 0.0);
      out.newTP                = root.GetDouble("new_tp", 0.0);
      out.trailDistancePoints  = root.GetDouble("trail_distance_points", 0.0);
      out.closeFraction        = root.GetDouble("close_fraction", 0.0);
      out.reason               = root.GetString("reason", "");
      out.valid                = true;
      delete root;
      return true;
     }
  };
//+------------------------------------------------------------------+
