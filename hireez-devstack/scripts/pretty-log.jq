# Turns the JSON log lines of the local services into short, colored lines.
# Use: jq -Rr --unbuffered --argjson color true -f pretty-log.jq <log>
# A line that is not JSON prints unchanged. $color false prints no ANSI codes.

def c($code): if $color then "\u001b[\($code)m" else "" end;
def reset: c("0");
def level_color:
  ascii_downcase
  | if test("^(error|fatal|critical)") then "1;31"
    elif test("^warn") then "33"
    elif test("^debug") then "34"
    else "32" end;

(fromjson? // null) as $j
| if ($j | type) != "object" then .
  else
    ($j.level // "" | tostring) as $lvl
    | ($j.timestamp // "" | tostring | if test("T") then .[11:19] else . end) as $time
    # nab writes `message`; htm-backend writes `content`, which is itself JSON text.
    | ($j.message // ($j.content | (fromjson? | .content? // .) // $j.content) // ""
       | if type == "string" then . else tojson end) as $msg
    | c("2") + $time + reset + " "
      + c($lvl | level_color) + ($lvl | ascii_upcase | .[0:4]) + reset + " "
      + ($j.logger // $j.functionName // "" | tostring
         | if . == "" or . == "agent" then "" else c("36") + . + reset + " " end)
      + $msg
      + (if $j.exception then "\n" + c("31") + ($j.exception | tostring) + reset else "" end)
  end
