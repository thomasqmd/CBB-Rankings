# Exhibition scrape pilot (2025-26) — parked

**Decision:** exhibitions enter the model only if one or two sources carry them. ESPN bulk files,
the ESPN site API, CBBD (`seasonType=preseason` returns nothing) and NCAA.com scoreboards all
start at opening night; the only public record is each school's athletics site (~365 sources,
several platforms). Not used.

What the pilot showed about the school-site route:
- 280 of 365 D1 teams matched an ncaa.com slug by name; the rest need a manual crosswalk.
- Of 40 sampled schools, 17 had parseable Sidearm schedule pages; 16 were other platforms
  (WMT and others) and 7 failed or redirected.
- 15 of 17 Sidearm schools listed exhibitions, often against D1 teams (e.g. UConn vs Boston
  College, Memphis vs Auburn, North Dakota State at Minnesota).
- The "Exhibition" text match is too loose: it also caught postseason cards (e.g. "#1 Duke
  (1 seed)", seeded conference-tournament games), so the table below over-counts.


D1 teams matched to an ncaa.com school slug: 280 of 365.
Random sample of 40 matched schools; one request per second, pages cached in data/raw/sites/.

## Coverage

|status         | schools|
|:--------------|-------:|
|fetch_failed   |       6|
|sidearm        |      17|
|unparsed_other |      14|
|unparsed_wmt   |       2|
|wrong_season   |       1|

Sidearm schools with at least one exhibition listed: 15 of 17.

## Exhibitions found

|team               |date       |venue |opponent                    |opp_level             |result | pts| opp_pts|
|:------------------|:----------|:-----|:---------------------------|:---------------------|:------|---:|-------:|
|Northern Iowa      |2025-11-01 |vs    |Upper Iowa (Exhibition)     |non-D1 (or unmatched) |W      |  96|      67|
|Northern Iowa      |NA         |vs    |#10/9 St. John's            |D1                    |L      |  53|      79|
|Florida State      |2025-10-16 |vs    |Alabama                     |D1                    |L      | 105|     109|
|Florida State      |2025-10-26 |vs    |Florida A&M                 |D1                    |W      |  88|      54|
|Florida State      |NA         |vs    |#1 Duke (1 seed)            |non-D1 (or unmatched) |L      |  79|      80|
|Baylor             |NA         |vs    |Oklahoma                    |D1                    |L      |  69|      82|
|Charlotte          |NA         |vs    |(1) South Florida           |D1                    |L      |  64|      86|
|Kent State         |NA         |at    |Illinois State              |D1                    |L      |  58|      79|
|North Dakota State |2025-10-16 |at    |Minnesota                   |D1                    |L      |  54|      80|
|North Dakota State |2025-10-23 |vs    |MSU Moorhead                |non-D1 (or unmatched) |W      | 101|      69|
|North Dakota State |NA         |vs    |(3) Michigan State          |D1                    |L      |  67|      92|
|Richmond           |2025-10-25 |vs    |JMU (Exhibition)            |non-D1 (or unmatched) |W      |  63|      58|
|Richmond           |NA         |NA    |NA                          |non-D1 (or unmatched) |L      |  67|      75|
|Drexel             |2025-10-28 |vs    |Lafayette (Exhibition)      |non-D1 (or unmatched) |NA     |  NA|      NA|
|Drexel             |NA         |vs    |Monmouth                    |D1                    |L      |  57|      65|
|DePaul             |NA         |vs    |Georgetown                  |D1                    |L      |  56|      63|
|Missouri State     |2025-10-31 |vs    |Maryville University (Exh.) |non-D1 (or unmatched) |W      |  92|      67|
|Missouri State     |NA         |vs    |(4) LA Tech                 |non-D1 (or unmatched) |L      |  66|      69|
|Memphis            |2025-10-30 |vs    |#20/22 Auburn               |D1                    |L      |  71|     100|
|Memphis            |NA         |vs    |No. 9 Tulane                |non-D1 (or unmatched) |L      |  69|      81|
|Toledo             |NA         |vs    |#2 Akron                    |D1                    |L      |  76|      79|
|Akron              |NA         |NA    |NA                          |non-D1 (or unmatched) |L      |  71|      91|
|Ohio State         |NA         |vs    |TCU                         |D1                    |L      |  64|      66|
|Texas Tech         |NA         |vs    |No. 4 Alabama               |non-D1 (or unmatched) |L      |  65|      90|

## Schools

|    |team               |conf          |slug              |site                           |status         | n_exh|
|:---|:------------------|:-------------|:-----------------|:------------------------------|:--------------|-----:|
|127 |Vermont            |Am. East      |vermont           |https://uvmathletics.com       |unparsed_other |     0|
|238 |Louisiana Tech     |CUSA          |louisiana-tech    |https://latechsports.com       |sidearm        |     0|
|348 |Wyoming            |Mountain West |wyoming           |https://gowyo.com              |unparsed_other |     0|
|275 |Northern Iowa      |MVC           |uni               |https://unipanthers.com        |sidearm        |     2|
|143 |Old Dominion       |Sun Belt      |old-dominion      |https://odusports.com          |fetch_failed   |     0|
|211 |Elon               |CAA           |elon              |https://elonphoenix.com        |unparsed_other |     0|
|27  |Florida State      |ACC           |florida-st        |https://seminoles.com          |sidearm        |     3|
|78  |Nebraska           |Big Ten       |nebraska          |https://huskers.com            |fetch_failed   |     0|
|113 |Baylor             |Big 12        |baylor            |https://baylorbears.com        |sidearm        |     1|
|345 |Green Bay          |Horizon       |green-bay         |https://greenbayphoenix.com    |unparsed_other |     0|
|259 |Charlotte          |American      |charlotte         |https://charlotte49ers.com     |sidearm        |     1|
|162 |Evansville         |MVC           |evansville        |https://gopurpleaces.com       |unparsed_other |     0|
|184 |Binghamton         |Am. East      |binghamton        |https://bubearcats.com         |unparsed_other |     0|
|231 |Kent State         |MAC           |kent-st           |https://kentstatesports.com    |sidearm        |     1|
|26  |Florida A&M        |SWAC          |florida-am        |https://famuathletics.com      |unparsed_other |     0|
|269 |North Dakota State |Summit        |north-dakota-st   |https://gobison.com            |sidearm        |     3|
|124 |Richmond           |A-10          |richmond          |https://richmondspiders.com    |sidearm        |     2|
|205 |Drexel             |CAA           |drexel            |https://drexeldragons.com      |sidearm        |     2|
|317 |Stony Brook        |CAA           |stony-brook       |https://goseawolves.org        |wrong_season   |     0|
|215 |Fordham            |A-10          |fordham           |https://fordhamsports.com      |unparsed_other |     0|
|149 |DePaul             |Big East      |depaul            |https://depaulbluedemons.com   |sidearm        |     1|
|318 |Missouri State     |CUSA          |missouri-st       |https://missouristatebears.com |sidearm        |     2|
|4   |Arkansas           |SEC           |arkansas          |https://arkansasrazorbacks.com |fetch_failed   |     0|
|225 |Houston Christian  |Southland     |houston-christian |https://hbuhuskies.com         |unparsed_other |     0|
|110 |Memphis            |American      |memphis           |https://gotigersgo.com         |sidearm        |     2|
|55  |Holy Cross         |Patriot       |holy-cross        |https://goholycross.com        |unparsed_other |     0|
|330 |Toledo             |MAC           |toledo            |https://utrockets.com          |sidearm        |     1|
|351 |Grambling          |SWAC          |grambling         |https://gsutigers.com          |unparsed_other |     0|
|9   |San Diego State    |Mountain West |san-diego-st      |https://goaztecs.com           |fetch_failed   |     0|
|217 |Gardner-Webb       |Big South     |gardner-webb      |https://gwusports.com          |sidearm        |     0|
|303 |Siena              |Metro         |siena             |https://sienasaints.com        |unparsed_other |     0|
|327 |Texas Southern     |SWAC          |texas-southern    |https://athletics.tsu.edu      |unparsed_other |     0|
|38  |Bradley            |MVC           |bradley           |https://bradleybraves.com      |unparsed_wmt   |     0|
|44  |Notre Dame         |ACC           |notre-dame        |https://und.com                |fetch_failed   |     0|
|39  |Northwestern       |Big Ten       |northwestern      |https://nusports.com           |unparsed_wmt   |     0|
|172 |Akron              |MAC           |akron             |https://gozips.com             |sidearm        |     1|
|183 |Bethune-Cookman    |SWAC          |bethune-cookman   |https://bcuathletics.com       |unparsed_other |     0|
|92  |Ohio State         |Big Ten       |ohio-st           |https://ohiostatebuckeyes.com  |sidearm        |     1|
|230 |Kansas State       |Big 12        |kansas-st         |https://kstatesports.com       |fetch_failed   |     0|
|328 |Texas Tech         |Big 12        |texas-tech        |https://texastech.com          |sidearm        |     1|
