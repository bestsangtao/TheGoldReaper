//+------------------------------------------------------------------+
//|                                                        Json.mqh  |
//|  Minimal, dependency-free JSON reader/writer for MQL5.           |
//|  Supports object/array/string/number/bool/null parsing and       |
//|  simple by-key / by-index access, plus a small escaping helper   |
//|  used when building request payloads.                            |
//+------------------------------------------------------------------+
#property strict

enum ENUM_JSON_TYPE
  {
   JSON_NULL,
   JSON_BOOL,
   JSON_NUMBER,
   JSON_STRING,
   JSON_ARRAY,
   JSON_OBJECT
  };

//+------------------------------------------------------------------+
//| JSON escape helper - used when embedding raw text into a JSON    |
//| string value (e.g. the natural-language prompt sent to Gemini).  |
//+------------------------------------------------------------------+
string JsonEscape(const string text)
  {
   string out = "";
   int len = StringLen(text);
   for(int i = 0; i < len; i++)
     {
      ushort c = StringGetCharacter(text, i);
      switch(c)
        {
         case '"':  out += "\\\""; break;
         case '\\': out += "\\\\"; break;
         case '\n': out += "\\n";  break;
         case '\r': out += "\\r";  break;
         case '\t': out += "\\t";  break;
         default:
            if(c < 0x20)
              {
               out += StringFormat("\\u%04x", c);
              }
            else
              {
               out += ShortToString(c);
              }
            break;
        }
     }
   return out;
  }

//+------------------------------------------------------------------+
//| CJsonValue - a parsed JSON node (object/array/scalar).            |
//+------------------------------------------------------------------+
class CJsonValue
  {
private:
   ENUM_JSON_TYPE    m_type;
   string            m_strVal;
   double            m_numVal;
   bool              m_boolVal;
   CJsonValue       *m_items[];   // array elements OR object values (parallel to m_keys)
   string            m_keys[];    // only used when m_type == JSON_OBJECT

   static void       SkipWs(const string &s, int &pos, int len)
     {
      while(pos < len)
        {
         ushort c = StringGetCharacter(s, pos);
         if(c == ' ' || c == '\t' || c == '\n' || c == '\r')
            pos++;
         else
            break;
        }
     }

   static CJsonValue *ParseString(const string &s, int &pos, int len)
     {
      CJsonValue *v = new CJsonValue();
      v.m_type = JSON_STRING;
      string result = "";
      pos++; // skip opening quote
      while(pos < len)
        {
         ushort c = StringGetCharacter(s, pos);
         if(c == '"')
           {
            pos++;
            break;
           }
         if(c == '\\')
           {
            pos++;
            ushort esc = StringGetCharacter(s, pos);
            switch(esc)
              {
               case 'n': result += "\n"; break;
               case 't': result += "\t"; break;
               case 'r': result += "\r"; break;
               case 'b': result += "\b"; break;
               case 'f': result += "\f"; break;
               case '"': result += "\""; break;
               case '\\': result += "\\"; break;
               case '/': result += "/"; break;
               case 'u':
                 {
                  string hex = StringSubstr(s, pos + 1, 4);
                  long code = StringToInteger("0x" + hex);
                  result += ShortToString((ushort)code);
                  pos += 4;
                  break;
                 }
               default:
                  result += ShortToString(esc);
                  break;
              }
            pos++;
           }
         else
           {
            result += ShortToString(c);
            pos++;
           }
        }
      v.m_strVal = result;
      return v;
     }

   static CJsonValue *ParseNumber(const string &s, int &pos, int len)
     {
      int start = pos;
      while(pos < len)
        {
         ushort c = StringGetCharacter(s, pos);
         if((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E')
            pos++;
         else
            break;
        }
      CJsonValue *v = new CJsonValue();
      v.m_type = JSON_NUMBER;
      v.m_numVal = StringToDouble(StringSubstr(s, start, pos - start));
      return v;
     }

   static CJsonValue *ParseLiteral(const string &s, int &pos, int len)
     {
      CJsonValue *v = new CJsonValue();
      if(StringSubstr(s, pos, 4) == "true")
        {
         v.m_type = JSON_BOOL; v.m_boolVal = true; pos += 4;
        }
      else if(StringSubstr(s, pos, 5) == "false")
        {
         v.m_type = JSON_BOOL; v.m_boolVal = false; pos += 5;
        }
      else if(StringSubstr(s, pos, 4) == "null")
        {
         v.m_type = JSON_NULL; pos += 4;
        }
      else
        {
         // malformed input - advance one char to avoid infinite loop
         v.m_type = JSON_NULL; pos++;
        }
      return v;
     }

   static CJsonValue *ParseArray(const string &s, int &pos, int len)
     {
      CJsonValue *v = new CJsonValue();
      v.m_type = JSON_ARRAY;
      pos++; // skip '['
      SkipWs(s, pos, len);
      if(pos < len && StringGetCharacter(s, pos) == ']')
        {
         pos++;
         return v;
        }
      while(pos < len)
        {
         SkipWs(s, pos, len);
         CJsonValue *item = ParseValue(s, pos, len);
         int n = ArraySize(v.m_items);
         ArrayResize(v.m_items, n + 1);
         v.m_items[n] = item;
         SkipWs(s, pos, len);
         if(pos < len && StringGetCharacter(s, pos) == ',')
           {
            pos++;
            continue;
           }
         if(pos < len && StringGetCharacter(s, pos) == ']')
           {
            pos++;
            break;
           }
         break;
        }
      return v;
     }

   static CJsonValue *ParseObject(const string &s, int &pos, int len)
     {
      CJsonValue *v = new CJsonValue();
      v.m_type = JSON_OBJECT;
      pos++; // skip '{'
      SkipWs(s, pos, len);
      if(pos < len && StringGetCharacter(s, pos) == '}')
        {
         pos++;
         return v;
        }
      while(pos < len)
        {
         SkipWs(s, pos, len);
         if(pos >= len || StringGetCharacter(s, pos) != '"')
            break;
         CJsonValue *keyNode = ParseString(s, pos, len);
         string key = keyNode.m_strVal;
         delete keyNode;
         SkipWs(s, pos, len);
         if(pos < len && StringGetCharacter(s, pos) == ':')
            pos++;
         SkipWs(s, pos, len);
         CJsonValue *val = ParseValue(s, pos, len);
         int n = ArraySize(v.m_items);
         ArrayResize(v.m_items, n + 1);
         ArrayResize(v.m_keys, n + 1);
         v.m_items[n] = val;
         v.m_keys[n] = key;
         SkipWs(s, pos, len);
         if(pos < len && StringGetCharacter(s, pos) == ',')
           {
            pos++;
            continue;
           }
         if(pos < len && StringGetCharacter(s, pos) == '}')
           {
            pos++;
            break;
           }
         break;
        }
      return v;
     }

   static CJsonValue *ParseValue(const string &s, int &pos, int len)
     {
      SkipWs(s, pos, len);
      if(pos >= len)
        {
         CJsonValue *v = new CJsonValue();
         v.m_type = JSON_NULL;
         return v;
        }
      ushort c = StringGetCharacter(s, pos);
      if(c == '{') return ParseObject(s, pos, len);
      if(c == '[') return ParseArray(s, pos, len);
      if(c == '"') return ParseString(s, pos, len);
      if(c == 't' || c == 'f' || c == 'n') return ParseLiteral(s, pos, len);
      return ParseNumber(s, pos, len);
     }

public:
                     CJsonValue() { m_type = JSON_NULL; m_numVal = 0; m_boolVal = false; }
                    ~CJsonValue()
     {
      for(int i = 0; i < ArraySize(m_items); i++)
         if(CheckPointer(m_items[i]) == POINTER_DYNAMIC)
            delete m_items[i];
     }

   static CJsonValue *Parse(const string &text)
     {
      int pos = 0;
      int len = StringLen(text);
      return ParseValue(text, pos, len);
     }

   ENUM_JSON_TYPE    Type() const { return m_type; }
   bool              IsNull() const { return m_type == JSON_NULL; }

   int               Size() const { return ArraySize(m_items); }

   // ---- object access -------------------------------------------------
   CJsonValue       *Get(const string key) const
     {
      if(m_type != JSON_OBJECT)
         return NULL;
      for(int i = 0; i < ArraySize(m_keys); i++)
         if(m_keys[i] == key)
            return m_items[i];
      return NULL;
     }

   bool              HasKey(const string key) const { return Get(key) != NULL; }

   // ---- array access ----------------------------------------------------
   CJsonValue       *At(const int index) const
     {
      if(index < 0 || index >= ArraySize(m_items))
         return NULL;
      return m_items[index];
     }

   // ---- scalar conversions ----------------------------------------------
   string            AsString() const
     {
      switch(m_type)
        {
         case JSON_STRING: return m_strVal;
         case JSON_NUMBER:  return DoubleToString(m_numVal, 8);
         case JSON_BOOL:    return m_boolVal ? "true" : "false";
         default:           return "";
        }
     }

   double            AsDouble() const
     {
      switch(m_type)
        {
         case JSON_NUMBER: return m_numVal;
         case JSON_STRING:  return StringToDouble(m_strVal);
         case JSON_BOOL:    return m_boolVal ? 1.0 : 0.0;
         default:           return 0.0;
        }
     }

   long              AsInt() const { return (long)MathRound(AsDouble()); }
   bool              AsBool() const
     {
      if(m_type == JSON_BOOL) return m_boolVal;
      if(m_type == JSON_STRING) return (m_strVal == "true" || m_strVal == "1");
      if(m_type == JSON_NUMBER) return m_numVal != 0.0;
      return false;
     }

   // ---- convenience getters with defaults (never return NULL) -----------
   string            GetString(const string key, const string def = "") const
     {
      CJsonValue *v = Get(key);
      return (v == NULL || v.IsNull()) ? def : v.AsString();
     }

   double            GetDouble(const string key, const double def = 0.0) const
     {
      CJsonValue *v = Get(key);
      return (v == NULL || v.IsNull()) ? def : v.AsDouble();
     }

   long              GetInt(const string key, const long def = 0) const
     {
      CJsonValue *v = Get(key);
      return (v == NULL || v.IsNull()) ? def : v.AsInt();
     }

   bool              GetBool(const string key, const bool def = false) const
     {
      CJsonValue *v = Get(key);
      return (v == NULL || v.IsNull()) ? def : v.AsBool();
     }
  };
//+------------------------------------------------------------------+
