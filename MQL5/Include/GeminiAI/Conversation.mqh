//+------------------------------------------------------------------+
//|                                              Conversation.mqh    |
//|  Rolling multi-turn conversation history for a Gemini thread.    |
//|                                                                    |
//|  The Gemini generateContent endpoint is stateless: it only        |
//|  "remembers" what the client resends in the "contents" array.     |
//|  This class stores the recent (role, text) turns so each new call |
//|  can include them - giving the model continuity across calls      |
//|  (exactly how the web chat works under the hood) without any web   |
//|  scraping.                                                         |
//|                                                                    |
//|  Turns are always added as user+model PAIRS (only after a call    |
//|  succeeds), so the stored history always starts with a user turn   |
//|  and strictly alternates user/model - which the API requires.     |
//|  To keep token cost bounded, callers store a COMPACT summary for   |
//|  the user turn (not the full OHLC snapshot) while still sending    |
//|  the full data in the live/current turn.                          |
//+------------------------------------------------------------------+
#property strict
#include <GeminiAI/Json.mqh>

class CConversation
  {
private:
   string            m_roles[];   // "user" | "model", strictly alternating
   string            m_texts[];
   int               m_maxMsgs;   // max stored messages (= maxTurns * 2); 0 disables memory

   void              TrimToLimit()
     {
      if(m_maxMsgs <= 0)
        {
         ArrayResize(m_roles, 0);
         ArrayResize(m_texts, 0);
         return;
        }
      // drop oldest whole (user,model) pairs so the array still starts with "user"
      while(ArraySize(m_roles) > m_maxMsgs)
        {
         int n = ArraySize(m_roles);
         int drop = (int)MathMin(2, n);
         for(int i = 0; i < n - drop; i++)
           {
            m_roles[i] = m_roles[i + drop];
            m_texts[i] = m_texts[i + drop];
           }
         ArrayResize(m_roles, n - drop);
         ArrayResize(m_texts, n - drop);
        }
     }

public:
                     CConversation() { m_maxMsgs = 0; ArrayResize(m_roles, 0); ArrayResize(m_texts, 0); }

   //--- maxTurns = how many user+model exchanges to keep (0 = stateless / memory off)
   void              Init(const int maxTurns)
     {
      m_maxMsgs = (maxTurns > 0) ? maxTurns * 2 : 0;
      ArrayResize(m_roles, 0);
      ArrayResize(m_texts, 0);
     }

   void              Clear() { ArrayResize(m_roles, 0); ArrayResize(m_texts, 0); }
   int               Size() const { return ArraySize(m_roles); }
   bool              Enabled() const { return m_maxMsgs > 0; }

   //--- record a completed exchange: the compact user summary + the model's full reply
   void              AddExchange(const string userSummary, const string modelText)
     {
      if(m_maxMsgs <= 0)
         return;
      int n = ArraySize(m_roles);
      ArrayResize(m_roles, n + 2);
      ArrayResize(m_texts, n + 2);
      m_roles[n]     = "user";  m_texts[n]     = userSummary;
      m_roles[n + 1] = "model"; m_texts[n + 1] = modelText;
      TrimToLimit();
     }

   //--- builds the JSON value for the "contents" field: stored history followed by the
   //--- current live user turn (which carries the full prompt + data).
   string            BuildContents(const string currentUserText) const
     {
      string s = "[";
      for(int i = 0; i < ArraySize(m_roles); i++)
         s += StringFormat("{\"role\":\"%s\",\"parts\":[{\"text\":\"%s\"}]},", m_roles[i], JsonEscape(m_texts[i]));
      s += StringFormat("{\"role\":\"user\",\"parts\":[{\"text\":\"%s\"}]}", JsonEscape(currentUserText));
      s += "]";
      return s;
     }
  };
//+------------------------------------------------------------------+
