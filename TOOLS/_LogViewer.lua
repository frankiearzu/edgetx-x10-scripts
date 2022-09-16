---- #########################################################################
---- #                                                                       #
---- # License GPLv2: http://www.gnu.org/licenses/gpl-2.0.html               #
---- #                                                                       #
---- # This program is free software; you can redistribute it and/or modify  #
---- # it under the terms of the GNU General Public License version 2 as     #
---- # published by the Free Software Foundation.                            #
---- #                                                                       #
---- # This program is distributed in the hope that it will be useful        #
---- # but WITHOUT ANY WARRANTY; without even the implied warranty of        #
---- # MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         #
---- # GNU General Public License for more details.                          #
---- #                                                                       #
---- #########################################################################

-- This script display a log file as a graph
-- Original Author: Herman Kruisman (RealTadango) (original version: https://raw.githubusercontent.com/RealTadango/FrSky/master/OpenTX/LView/LView.lua)
-- Current Author: Offer Shmuely
-- Date: 2022
-- ver: 0.1



--function cache
local math_floor = math.floor
local math_fmod = math.fmod
local string_gmatch = string.gmatch
local string_gsub = string.gsub
local string_len = string.len

local heap = 2048
local hFile

local log_file_list = {}
local filter_model_name
local filter_date
local model_name_list = { "-- all -- (not working yet)" }
local date_list = { "-- all -- (not working yet)" }
local accuracy_list = { "1/1 (read every line)", "1/2 (every 2nd line)", "1/5 (every 5th line)", "1/10 (every 10th line)" }
local filename

local columns = {}
local current_session = nil

-- state machine
local STATE = {
  SELECT_NA = 0,
  SELECT_FILE_INIT = 1,
  SELECT_FILE = 2,
  READ_FILE_HEADER = 3,
  SELECT_SENSORS_INIT = 4,
  SELECT_SENSORS = 5,
  READ_FILE_DATA = 6,
  PARSE_DATA = 7,
  SHOW_GRAPH = 8
}

local state = STATE.SELECT_NA
local points = {}
local conversionStep = 0
local conversionIndex = 0

--File reading data
local valPos = 0
local skipLines = 0
local lines = 0
local index = 0
local buffer = ""
local prevTotalSeconds = 0

--Option data
--local maxLines
local current_option = 1

local sensorSelection = {
  { y = 80, label = "Var 1", values = {}, value = 1, min = 0 },
  { y = 105, label = "Var 2", values = {}, value = 0, min = 0 },
  { y = 130, label = "Var 3", values = {}, value = 0, min = 0 },
  { y = 155, label = "Var 4", values = {}, value = 0, min = 0 }
}

--Graph data
local values = {}

local graphConfig = {
  --x_start = 60,
  x_start = 0,
  --x_end = 420,
  x_end = LCD_W,
  y_start = 40,
  y_end = 240,
  { color = BLUE, valx = 80, valy = 249, minx = 5, miny = 220, maxx = 5, maxy = 30 },
  { color = GREEN, valx = 170, valy = 249, minx = 5, miny = 205, maxx = 5, maxy = 45 },
  { color = RED, valx = 265, valy = 249, minx = 5, miny = 190, maxx = 5, maxy = 60 },
  { color = WHITE, valx = 380, valy = 249, minx = 5, miny = 175, maxx = 5, maxy = 75 }
}

local xStep = (graphConfig.x_end - graphConfig.x_start) / 100

local cursor = 0

local GRAPH_CURSOR = 0
local GRAPH_ZOOM = 1
local GRAPH_SCROLL = 2
local GRAPH_MINMAX = 3
local graphMode = GRAPH_CURSOR
local graphStart = 0
local graphSize = 0
local graphTimeBase = 0
local graphMinMaxIndex = 0

--------------------------------------------------------------
-- Return GUI library table
function loadGUI()
  if not libGUI then
    -- Loadable code chunk is called immediately and returns libGUI
    libGUI = loadScript("/SCRIPTS/TOOLS/LogViewer/libgui.lua")
  end

  return libGUI()
end

-- Load the GUI library by calling the global function declared in the main script.
-- As long as LibGUI is on the SD card, any widget can call loadGUI() because it is global.

local libGUI = loadGUI()

-- Instantiate a new GUI object
local ctx1 = libGUI.newGUI()
local ctx2 = libGUI.newGUI()

-----------------------------------------------------------------
local function log(s)
  print("LogViewer: " .. s)
end
local function log1(fmt, val1)
  log(string.format(fmt, val1))
end
local function log2(fmt, val1, val2)
  log(string.format(fmt, val1, val2))
end
local function log3(fmt, val1, val2, val3)
  log(string.format(fmt, val1, val2, val3))
end

function tprint (t, s)
  for k, v in pairs(t) do
    local kfmt = '["' .. tostring(k) .. '"]'
    if type(k) ~= 'string' then
      kfmt = '[' .. k .. ']'
    end
    local vfmt = '"' .. tostring(v) .. '"'
    if type(v) == 'table' then
      tprint(v, (s or '') .. kfmt)
    else
      if type(v) ~= 'string' then
        vfmt = tostring(v)
      end
      print(type(t) .. (s or '') .. kfmt .. ' = ' .. vfmt)
    end
  end
end

--------------------------------------------------------------

local function doubleDigits(value)
  if value < 10 then
    return "0" .. value
  else
    return value
  end
end

local function toDuration1(totalSeconds)
  local hours = math_floor(totalSeconds / 3600)
  totalSeconds = totalSeconds - (hours * 3600)
  local minutes = math_floor(totalSeconds / 60)
  local seconds = totalSeconds - (minutes * 60)

  return doubleDigits(hours) .. ":" .. doubleDigits(minutes) .. ":" .. doubleDigits(seconds);
end

local function toDuration2(totalSeconds)
  local minutes = math_floor(totalSeconds / 60)
  local seconds = totalSeconds - (minutes * 60)

  return doubleDigits(minutes) .. "." .. doubleDigits(seconds) .. "min";

  --local minutes = math_floor(totalSeconds / 60)
  --return minutes .. " minutes";
  --return totalSeconds .. " sec";
end

local function split(text)
  local cnt = 0
  local result = {}
  for val in string_gmatch(string_gsub(text, ",,", ", ,"), "([^,]+),?") do
    result[cnt] = val
    cnt = cnt + 1
  end

  return result, cnt
end

local function getTotalSeconds(time)
  local total = tonumber(string.sub(time, 1, 2)) * 3600
  total = total + tonumber(string.sub(time, 4, 5)) * 60
  total = total + tonumber(string.sub(time, 7, 8))

  return total
end

local function readHeader(file)
  local read = io.read(file, 2048)

  index = string.find(read, "\n")

  if index ~= nil then
    io.seek(file, index)

    local headerLine = string.sub(read, 0, index - 1)

    local columns_temp = split(headerLine)
    for i = 2, #columns_temp, 1 do
      local col = columns_temp[i]
      columns[#columns + 1] = col
    end
    return true
  end

  return false
end

local function readFile()
  local read = io.read(hFile, heap)

  if read == "" then
    io.close(hFile)
    return true
  end

  local indexOffset = string_len(buffer)

  buffer = buffer .. read
  local i = 0

  for line in string_gmatch(buffer, "([^\n]+)\n") do
    --log2("\n%d.\n %s \n\n", lines, line)
    lines = lines + 1

    --if math_fmod(lines, skipLines) == 0 then
    if math_fmod(lines, 1) == 0 then
      local time = string.sub(line, 12, 19)
      local totalSeconds = getTotalSeconds(time);

      --log(string.format("line: %d. %s %dsec", lines, time, totalSeconds))
      if lines == 1 then
        current_session = {
          startTime = time,
          --startLine = lines,
          startIndex = index + i - indexOffset
        }
      end

      current_session.endTime = time
      current_session.total_lines = lines
      current_session.endIndex = index + i

      prevTotalSeconds = totalSeconds
    end

    i = i + string_len(line) + 1 --dont forget the newline ;)
  end

  buffer = string.sub(buffer, i + 1) --dont forget the newline ;
  index = index + heap
  io.seek(hFile, index)

  return false
end

local function fileGetSize(hFile)
  local read = io.read(hFile, heap)

  if read == "" then
    --io.close(hFile)
    return -1
  end

  local buffer = ""
  local line_num = 0
  buffer = buffer .. read

  for line in string_gmatch(buffer, "([^\n]+)\n") do
    line_num = line_num + 1
  end

  return line_num
end

local function collectData(file)
  local read = io.read(file, heap)

  if read == "" then
    io.close(file)
    return true
  end

  buffer = buffer .. read
  local i = 0

  for line in string_gmatch(buffer, "([^\n]+)\n") do
    if math_fmod(lines, skipLines) == 0 then
      vals = split(line)

      for varIndex = 1, 4, 1 do
        if sensorSelection[varIndex].value ~= 0 then
          values[varIndex][valPos] = vals[sensorSelection[varIndex].value + 1]
        end
      end

      valPos = valPos + 1
    end

    lines = lines + 1

    if lines > current_session.total_lines then
      io.close(file)
      return true
    end

    i = i + string_len(line) + 1 --dont forget the newline ;)
  end

  buffer = string.sub(buffer, i + 1) --dont forget the newline ;
  index = index + heap
  io.seek(file, index)

  return false
end

local function initFile()
  hFile = io.open("/LOGS/" .. filename, "r")
  if hFile == nil then
    return "Cannot open file?"
  end

  if not readHeader(hFile) then
    return "Header could not be found"
  end

  return nil
end

local function drawMain()
  lcd.clear()

  -- draw background
  --lcd.drawFilledRectangle(0, 0, LCD_W, LCD_H, COLOR_THEME_SECONDARY3)
  if state ~= STATE.SHOW_GRAPH then
    lcd.drawFilledRectangle(0, 0, LCD_W, LCD_H, WHITE)
  else
    lcd.drawFilledRectangle(0, 0, LCD_W, LCD_H, BLACK)
  end

  -- draw top-bar
  lcd.drawFilledRectangle(0, 0, LCD_W, 20, TITLE_BGCOLOR)
  lcd.setColor(CUSTOM_COLOR, lcd.RGB(193, 198, 215))
  --lcd.drawFilledRectangle(0, 0, LCD_W, 20, CUSTOM_COLOR) --"#BDC2D3"
  --lcd.drawFilledRectangle(0, 0, LCD_W, 20, BLACK) --"#BDC2D3"
  --lcd.drawFilledRectangle(0, 0, LCD_W, 20, COLOR_THEME_PRIMARY3)

  if filename ~= nil then
    --lcd.setColor(CUSTOM_COLOR, lcd.RGB(93,130,244))
    --lcd.drawText(30, 1, "/LOGS/" .. filename, CUSTOM_COLOR + SMLSIZE)
    lcd.drawText(30, 1, "/LOGS/" .. filename, WHITE + SMLSIZE)
    --lcd.drawText(8, 1, "/LOGS/" .. filename, MENU_TITLE_COLOR + SMLSIZE)
  end
end

local function drawOption(y, label, value, select_index)
  --log1("drawOption: %s", label)
  local activeOption = current_option == select_index
  local w, h = lcd.sizeText(value)

  -- draw label
  --log1("drawOption: %s", label)
  lcd.drawText(10, y, label, TEXT_COLOR)

  -- draw value
  lcd.drawRectangle(100, y, w + 20, 20, COLOR_THEME_SECONDARY2)
  if activeOption then
    --lcd.drawText(100, y, value, TEXT_INVERTED_COLOR + INVERS)
    lcd.drawFilledRectangle(100, y, w + 20, 20, COLOR_THEME_FOCUS)
    lcd.drawText(100 + 5, y, value, COLOR_THEME_PRIMARY2)
  else
    lcd.drawText(100 + 5, y, value, TEXT_COLOR)
  end
end

local function drawOptions(options)
  if current_option > #options then
    current_option = #options
  end

  for i = 1, #options, 1 do
    option = options[i]
    if option.value > #option.values then
      option.value = #option.values
    elseif option.value < option.min then
      option.value = option.min
    end
    drawOption(option.y, option.label, option.values[option.value], i)
  end
end

local function handleOptionInput(options, event)
  if event == EVT_VIRTUAL_NEXT_PAGE then
    current_option = current_option + 1
  elseif event == EVT_VIRTUAL_PREV_PAGE then
    current_option = current_option - 1
  end

  if current_option < 1 then
    current_option = 1
  elseif current_option > #options then
    current_option = #options
  end

  option = options[current_option]

  --if event == EVT_PLUS_FIRST or event == EVT_ROT_RIGHT or event == EVT_PLUS_REPT or event == EVT_VIRTUAL_NEXT_REPT then
  if event == EVT_VIRTUAL_NEXT then
    option.value = option.value + 1
    --elseif event == EVT_MINUS_FIRST or event == EVT_ROT_LEFT or event == EVT_MINUS_REPT then
  elseif event == EVT_VIRTUAL_PREV then
    option.value = option.value - 1
  end

  local maxOption = #option.values

  if option.max ~= nil then
    maxOption = option.max
  end

  if option.value < option.min then
    option.value = option.min
  elseif option.value > maxOption then
    option.value = maxOption
  end
end

local function drawGraph_base()
  --lcd.drawLine(graphConfig.x_start, graphConfig.y_start, graphConfig.x_start, graphConfig.y_end, SOLID, CUSTOM_COLOR)
  --lcd.drawLine(graphConfig.x_start, graphConfig.y_end, graphConfig.x_end, graphConfig.y_end, SOLID, CUSTOM_COLOR)
  --lcd.drawLine(graphConfig.x_end, graphConfig.y_start, graphConfig.x_end, graphConfig.y_end, SOLID, CUSTOM_COLOR)
  --lcd.drawLine(graphConfig.x_start, graphConfig.y_start, graphConfig.x_end, graphConfig.y_start, DOTTED, CUSTOM_COLOR)

  local mode_x = 390
  local mode_y = 1
  local txt = nil
  if graphMode == GRAPH_CURSOR then
    txt = "Cursor"
  elseif graphMode == GRAPH_ZOOM then
    txt = "Zoom"
  elseif graphMode == GRAPH_MINMAX then
    txt = "min/max"
  else
    txt = "Scroll"
  end
  lcd.drawFilledRectangle(mode_x, mode_y, 100, 18, DARKGREEN)
  --local mode_style = SMLSIZE + TEXT_INVERTED_COLOR + INVERS
  lcd.drawText(mode_x, mode_y, "Mode: " .. txt, SMLSIZE + WHITE)
end

local function drawGraph_points(points, min, max)
  if min == max then
    return
  end

  local yScale = (max - min) / 200

  prevY = graphConfig.y_end - ((points[0] - min) / yScale)

  if prevY > graphConfig.y_end then
    prevY = graphConfig.y_end
  elseif prevY < graphConfig.y_start then
    prevY = graphConfig.y_start
  end

  for i = 0, #points - 1, 1 do
    x1 = graphConfig.x_start + (xStep * i)
    y = graphConfig.y_end - ((points[i + 1] - min) / yScale)

    if y > graphConfig.y_end then
      y = graphConfig.y_end
    elseif y < graphConfig.y_start then
      y = graphConfig.y_start
    end

    lcd.drawLine(x1, prevY, x1 + xStep, y, SOLID, CUSTOM_COLOR)

    prevY = y
  end
end

local function drawGraph()
  skip = graphSize / 101

  lcd.setColor(CUSTOM_COLOR, BLACK)
  drawGraph_base()

  -- draw cursor
  local x = graphConfig.x_start + (xStep * cursor)
  lcd.drawLine(x, graphConfig.y_start, x, graphConfig.y_end, DOTTED, WHITE)

  local cursorLine = math_floor((graphStart + (cursor * skip)) / graphTimeBase)
  local cursorTime = toDuration1(cursorLine)

  if cursorLine < 3600 then
    cursorTime = string.sub(cursorTime, 4)
  end

  -- draw cursor time
  --lcd.drawText(5, 130, cursorTime, CUSTOM_COLOR)
  lcd.drawText(x, 20, cursorTime, WHITE)

  --Draw session view locations
  local viewScale = valPos / 479
  local viewStart = math.floor(graphStart / viewScale)
  local viewEnd = math.floor((graphStart + graphSize) / viewScale)

  lcd.setColor(CUSTOM_COLOR, RED)

  lcd.drawLine(viewStart, 269, viewEnd, 269, SOLID, CUSTOM_COLOR)
  lcd.drawLine(viewStart, 270, viewEnd, 270, SOLID, CUSTOM_COLOR)
  lcd.drawLine(viewStart, 271, viewEnd, 271, SOLID, CUSTOM_COLOR)

  -- draw min/max
  for varIndex = 1, 4, 1 do
    if sensorSelection[varIndex].value ~= 0 then
      local points = points[varIndex]
      local cfg = graphConfig[varIndex]

      if #points.points == 0 then
        for i = 0, 100, 1 do
          --print("i:" .. i .. ", skip: " .. skip .. ", result:" .. math_floor(graphStart + (i * skip)))
          points.points[i] = values[varIndex][math_floor(graphStart + (i * skip))]
          if points.points[i] == nil then
            points.points[i] = 0
          end
        end
      end

      lcd.setColor(CUSTOM_COLOR, cfg.color)
      drawGraph_points(points.points, points.min, points.max)

      local minPos = math_floor((points.minpos + 1 - graphStart) / skip)
      local maxPos = math_floor((points.maxpos + 1 - graphStart) / skip)

      if minPos < 0 then
        minPos = 0
      elseif minPos > 100 then
        minPos = 100
      end

      if maxPos < 0 then
        maxPos = 0
      elseif maxPos > 100 then
        maxPos = 100
      end

      local x = graphConfig.x_start + (minPos * xStep)
      lcd.drawLine(x, 240, x, 250, SOLID, CUSTOM_COLOR)

      local x = graphConfig.x_start + (maxPos * xStep)
      -- ??? graphConfig.y_end
      lcd.drawLine(x, 30, x, graphConfig.y_start, SOLID, CUSTOM_COLOR)

      -- draw max
      if graphMode == GRAPH_MINMAX and graphMinMaxIndex == (varIndex - 1) * 2 then
        local txt = string.format("Max: %d", points.max)
        local w, h = lcd.sizeText(txt, MIDSIZE)
        lcd.drawFilledRectangle(cfg.maxx, cfg.maxy, w + 4, h, GREY, 3)
        lcd.drawRectangle(cfg.maxx, cfg.maxy, w + 4, h, CUSTOM_COLOR)
        lcd.drawText(cfg.maxx, cfg.maxy, txt, MIDSIZE + CUSTOM_COLOR)
      else
        lcd.drawText(cfg.maxx, cfg.maxy, points.max, SMLSIZE + CUSTOM_COLOR)
      end

      -- draw min
      if graphMode == GRAPH_MINMAX and graphMinMaxIndex == ((varIndex - 1) * 2) + 1 then
        local txt = string.format("Min: %d", points.min)
        local w, h = lcd.sizeText(txt, MIDSIZE)
        lcd.drawFilledRectangle(cfg.minx, cfg.miny, w + 4, h, GREY, 5)
        lcd.drawRectangle(cfg.minx, cfg.miny, w + 4, h, CUSTOM_COLOR)
        lcd.drawText(cfg.minx, cfg.miny, txt, MIDSIZE + CUSTOM_COLOR)
        --lcd.drawText(cfg.minx, cfg.miny, points.min, MIDSIZE + TEXT_INVERTED_COLOR + INVERS)
      else
        lcd.drawText(cfg.minx, cfg.miny, points.min, SMLSIZE + CUSTOM_COLOR)
      end

      if points.points[cursor] ~= nil then
        lcd.drawText(cfg.valx, cfg.valy, points.name .. " " .. points.points[cursor], CUSTOM_COLOR)
      end
    end
  end
end

local function print_table(prefix, tbl)
  for i = 1, #tbl, 1 do
    local val = tbl[i]
    log(string.format("%d. %s: %s", i, prefix, val))
  end
end

-- read log file list
local function read_files_list()

  for fileName in dir("/LOGS") do
    log1("log file: %s (detecting...)", fileName)

    -- F3A UNI recorde-2022-02-09-082937.csv
    local modelName, year, month, day, hour, min, sec, m, d, y = string.match(fileName, "(.*)-(%d+)-(%d+)-(%d+)-(%d%d)(%d%d)(%d%d).csv")
    if modelName ~= nil then
      --log1("log file: %s (is csv)", fileName)
      log(string.format("modelName:%s, day:%s, month:%s, year:%s, hour:%s, min:%s, sec:%s", modelName, day, month, year, hour, min, sec))

      --log1("os.time", os.time{year=year, month=month, day=day, hour=hour, min=min, sec=sec})

      log_file_list[#log_file_list + 1] = fileName

      if model_name_list[#model_name_list] ~= modelName then
        model_name_list[#model_name_list + 1] = modelName
      end

      local model_day = string.format("%s-%s-%s", year, month, day)
      if date_list[#date_list] ~= model_day then
        date_list[#date_list + 1] = model_day
      end


      --local file = io.open("/LOGS/" .. fileName, "r")
      --if file ~= nil then
      --  --log(tostring(file))
      --  --local current = file:seek()      -- get current position
      --  --local size = file:seek("end")    -- get file size
      --  --file:seek("set", current)        -- restore position
      --
      --  local line_num = fileGetSize(file)
      --  log1("line_num: %s", line_num)
      --
      --
      --  --local file_size = io.seek(file, "end")
      --  --log1("file_size: %s",file_size )
      --
      --  if model_name_list[#model_name_list] ~= modelName then
      --    model_name_list[#model_name_list + 1] = modelName
      --  end
      --
      --  local model_day = string.format("%s-%s-%s", year, month, day)
      --  if date_list[#date_list] ~= model_day then
      --    date_list[#date_list + 1] = model_day
      --  end
      --
      --  io.close(file)
      --end

    end
  end

  function compare_file_names(a, b)
    a1 = string.sub(a, -21, -5)
    b1 = string.sub(b, -21, -5)
    --log2("ab, %s ? %s", a, b)
    --log1("a1, %s", a1)
    --log1("b1, %s ", b1)
    --log2("a1b1, %s ? %s", a1, b1)
    return a1 > b1
  end

  function compare_dates(a, b)
    return a > b
  end


  --print_table("log_file_list-non-sort", log_file_list)
  table.sort(log_file_list, compare_file_names)
  --log("after sort")
  --print_table("log_file_list-sort", log_file_list)



  --log("before sort2")
  --print_table("date_list-non-sort", date_list)
  table.sort(date_list, compare_dates)
  --log("after sort2")
  --print_table("date_list-sort", date_list)


end

local function init()
  read_files_list()
end

local function onDropDownChange(obj)
  local i = obj.selected
  --labelDropDown.title = "Selected switch: " .. dropDownItems[i] .. " [" .. dropDownIndices[i] .. "]"
  log("Selected switch: " .. i)
  log("Selected switch: " .. log_file_list[i])
  filename = log_file_list[i]
  log("filename: " .. filename)
end

local function onAccuracyChange(obj)
  local i = obj.selected
  accuracy = i
  log2("Selected accuracy: %s (%d)", accuracy_list[i], i)

  if accuracy == 4 then
    skipLines = 10
    heap = 2048 * 16
  elseif accuracy == 3 then
    skipLines = 5
    heap = 2048 * 16
  elseif accuracy == 2 then
    skipLines = 2
    heap = 2048 * 8
  else
    skipLines = 1
    heap = 2048 * 4
  end


end

local function filter_log_file_list(filter_model_name, filter_date)
  log2("need to filter by: %s, %s", filter_model_name, filter_date)
  --log_file_list = {"sss"}
end

local function state_SELECT_FILE_init(event, touchState)
  log("++++++++++++++++++++++++++++++++")
  --Menu that does nothing
  ctx1.label(10, 25, 120, 24, "Select log file...", BOLD)

  --local model_name_list = { "-- all --", "aaa", "bbb", "ccc" }
  --local date_list = { "-- all --", "2017", "2018", "2019" }
  ctx1.label(10, 55, 60, 24, "Model")
  ctx1.dropDown(90, 55, 380, 24, model_name_list, 1,
    function(obj)
      local i = obj.selected
      filter_model_name = model_name_list[i]
      log("Selected filter_date: " .. filter_model_name)
      filter_log_file_list(filter_model_name, filter_date)
    end
  )

  ctx1.label(10, 80, 60, 24, "Date")
  ctx1.dropDown(90, 80, 380, 24, date_list, 1,
    function(obj)
      local i = obj.selected
      filter_date = date_list[i]
      log("Selected filter_date: " .. filter_date)
      filter_log_file_list(filter_model_name, filter_date)
    end
  )

  ctx1.label(10, 105, 60, 24, "File")
  local dd3 = ctx1.dropDown(90, 105, 380, 24, log_file_list, 1, onDropDownChange)
  onDropDownChange(dd3)

  ctx1.label(10, 130, 60, 24, "Accuracy")
  dd4 = ctx1.dropDown(90, 130, 380, 24, accuracy_list, 1, onAccuracyChange)
  onAccuracyChange(dd4)

  state = STATE.SELECT_FILE
  return 0
end

local function state_SELECT_SENSORS_INIT(event, touchState)
  --Menu that does nothing
  ctx2.label(10, 25, 120, 24, "Select sensors...", BOLD)

  --local model_name_list = { "-- all --", "aaa", "bbb", "ccc" }
  --local date_list = { "-- all --", "2017", "2018", "2019" }
  ctx2.label(10, 55, 60, 24, "Var1")
  ctx2.dropDown(90, 55, 380, 24, columns, 1,
    function(obj)
      local i = obj.selected
      local var1 = columns[i]
      log("Selected var1: " .. var1)
      sensorSelection[1].value = i
    end
  )

  ctx2.label(10, 80, 60, 24, "Var2")
  ctx2.dropDown(90, 80, 380, 24, columns, 2,
    function(obj)
      local i = obj.selected
      local var2 = columns[i]
      log("Selected var2: " .. var2)
      sensorSelection[2].value = i
    end
  )

  ctx2.label(10, 105, 60, 24, "Var3")
  ctx2.dropDown(90, 105, 380, 24, columns, 3,
    function(obj)
      local i = obj.selected
      local var3 = columns[i]
      log("Selected var3: " .. var3)
      sensorSelection[3].value = i
    end
  )

  ctx2.label(10, 130, 60, 24, "Var4")
  ctx2.dropDown(90, 130, 380, 24, columns, 4,
    function(obj)
      local i = obj.selected
      local var4 = columns[i]
      log("Selected var4: " .. var4)
      sensorSelection[4].value = i
    end
  )

  state = STATE.SELECT_SENSORS
  return 0
end

local function state_SELECT_FILE_refresh(event, touchState)
  -- ## escape
  if event == EVT_VIRTUAL_EXIT then
    return 2
  end

  -- ## file selected
  if event == EVT_VIRTUAL_NEXT_PAGE then
    --Reset file load data
    log("Reset file load data")
    buffer = ""
    lines = 0
    heap = 2048 * 12
    prevTotalSeconds = 0

    local fileResult = initFile()
    if fileResult ~= nil then
      error(fileResult)
    end

    state = STATE.READ_FILE_HEADER
    return 0
  end

  -- --color test
  --local dx = 250
  --local dy = 50
  --lcd.drawText(dx, dy, "COLOR_THEME_PRIMARY1", COLOR_THEME_PRIMARY1)
  --dy = dy +20
  --lcd.drawText(dx, dy, "COLOR_THEME_PRIMARY2", COLOR_THEME_PRIMARY2)
  --dy = dy +20
  --lcd.drawText(dx, dy, "COLOR_THEME_PRIMARY3", COLOR_THEME_PRIMARY3)
  --dy = dy +20
  --lcd.drawText(dx, dy, "COLOR_THEME_SECONDARY1", COLOR_THEME_SECONDARY1)
  --dy = dy +20
  --lcd.drawText(dx, dy, "COLOR_THEME_SECONDARY2", COLOR_THEME_SECONDARY2)
  --dy = dy +20
  --lcd.drawText(dx, dy, "COLOR_THEME_SECONDARY3", COLOR_THEME_SECONDARY3)
  --dy = dy +20
  --lcd.drawText(dx, dy, "COLOR_THEME_FOCUS", COLOR_THEME_FOCUS)
  --dy = dy +20
  --lcd.drawText(dx, dy, "COLOR_THEME_EDIT", COLOR_THEME_EDIT)
  --dy = dy +20
  --lcd.drawText(dx, dy, "COLOR_THEME_ACTIVE", COLOR_THEME_ACTIVE)
  --dy = dy +20
  --lcd.drawText(dx, dy, "COLOR_THEME_WARNING", COLOR_THEME_WARNING)
  --dy = dy +20
  --lcd.drawText(dx, dy, "COLOR_THEME_DISABLED", COLOR_THEME_DISABLED)

  ctx1.run(event, touchState)

  return 0
end


local function state_READ_FILE_HEADER_refresh(event, touchState)
  log("state_READ_FILE_HEADER_refresh")
  if event == EVT_VIRTUAL_EXIT or event == EVT_VIRTUAL_PREV_PAGE then
    filename = nil
    state = STATE.SELECT_FILE
    return 0
  end

  lcd.drawText(5, 40, "Analysing file...", TEXT_COLOR)
  lcd.drawText(5, 60, "Found " .. lines .. " lines", TEXT_COLOR)
  --lcd.drawText(5, 80, "Found " .. sessionCount .. " sessions", TEXT_COLOR)
  if readFile() then
    for varIndex = 1, 4, 1 do
      sensorSelection[varIndex].values[0] = "---"
      for i = 2, #columns, 1 do
        sensorSelection[varIndex].values[i - 1] = columns[i]
      end
    end

    current_option = 1
    state = STATE.SELECT_SENSORS_INIT
  end

  return 0
end

local function state_SELECT_SENSORS_refresh(event, touchState)
  if event == EVT_VIRTUAL_EXIT then
    return 2

  elseif event == EVT_VIRTUAL_EXIT or event == EVT_VIRTUAL_PREV_PAGE then
    filename = nil

    state = STATE.SELECT_FILE_INIT
    return 0

    --elseif event == EVT_VIRTUAL_ENTER or event == EVT_ROT_BREAK then
  elseif event == EVT_VIRTUAL_NEXT_PAGE then
    buffer = ""
    hFile = io.open("/LOGS/" .. filename, "r")
    io.seek(hFile, current_session.startIndex)
    index = current_session.startIndex

    valPos = 0
    lines = 0
    --maxLines = current_session.total_lines - current_session.startLine
    log(string.format("current_session.total_lines: %d", current_session.total_lines))

    points = {}
    values = {}

    for varIndex = 1, 4, 1 do
      if sensorSelection[varIndex].value ~= 0 then
        points[varIndex] = {}
        values[varIndex] = {}
      end
    end

    state = STATE.READ_FILE_DATA
    return 0
  end

  --lcd.drawText(5, 25, "Select vars to display on graph...", TEXT_COLOR)
  --
  --drawOptions(sensorSelection)
  --handleOptionInput(sensorSelection, event)
  --
  --local duration = toDuration2(getTotalSeconds(current_session.endTime) - getTotalSeconds(current_session.startTime))
  --lcd.drawText(340, 200, string.format("time: %s", current_session.startTime), TEXT_COLOR)
  --lcd.drawText(340, 220, string.format("duration: %s", duration), TEXT_COLOR)
  ----lcd.drawText(100, 100, string.format("Duration %s (%d lines)", duration, lines), TEXT_COLOR)
  --lcd.drawText(340, 240, string.format("lines: %d", lines), TEXT_COLOR)

  ctx2.run(event, touchState)


  ---- draw sensor grid
  --local x = 10
  --local y = 50
  --local dx = 80
  --local dy = 25
  --local iCol = 2
  --for iy = 0, 10, 1 do
  --    for ix = 0, 5, 1 do
  --        if iCol < #columns then
  --
  --            local col_name = columns[iCol]
  --            log1("col: %s", columns[i])
  --
  --            lcd.drawFilledRectangle(x + dx * ix, y + dy * iy, 50, 16, TEXT_INVERTED_BGCOLOR)
  --            lcd.drawRectangle(x + dx * ix, y + dy * iy, 50, 20, TEXT_COLOR)
  --
  --            lcd.drawText(x + dx * ix + 5, y + dy * iy, col_name, SMLSIZE + TEXT_COLOR)
  --            iCol = iCol +1
  --        end
  --    end
  --
  --end

  ---- draw sensor grid
  --local x = 200
  --local y = 50
  --local dx = 80
  --local dy = 25
  --local iCol = 2
  --local ix = 0
  --for iy = 0, 10, 1 do
  --    if iCol < #columns then
  --
  --        local col_name = columns[iCol]
  --        log1("col: %s", columns[i])
  --
  --        lcd.drawFilledRectangle(x + dx * ix, y + dy * iy, 100, 20, TEXT_INVERTED_BGCOLOR)
  --        lcd.drawRectangle(x + dx * ix, y + dy * iy, 100, 20, TEXT_COLOR)
  --
  --        lcd.drawText(x + dx * ix + 5, y + dy * iy, col_name, SMLSIZE + TEXT_COLOR)
  --        iCol = iCol +1
  --    end
  --
  --end

  --for i = 1, #columns, 1 do
  --    local col_name = columns[i]
  --    log1("col: %s", columns[i])
  --    lcd.drawText(x + dx, y + dy, col_name, SMLSIZE + TEXT_COLOR)
  --    y = y +dy
  --    dx = math.floor(i / 10)
  --end

  return 0
end

local function drawProgress(y, current, total)
  log2(string.format("drawProgress(%d. %d, %d)", y, current, total))
  local x = 140
  local pct = current / total
  lcd.drawFilledRectangle(x + 1, y + 1, (470 - x - 2) * pct, 14, TEXT_INVERTED_BGCOLOR)
  lcd.drawRectangle(x, y, 470 - x, 16, TEXT_COLOR)
end

local function display_read_data(conversionStep, conversionIndex)
  log2("display_read_data(%d, %d)", conversionStep, conversionIndex)
  lcd.drawText(5, 25, "Reading data from file...", TEXT_COLOR)

  lcd.drawText(5, 60, "Reading line: " .. lines, TEXT_COLOR)
  drawProgress(60, lines, current_session.total_lines)

  local done_var_1 = 0
  local done_var_2 = 0
  local done_var_3 = 0
  local done_var_4 = 0
  if conversionStep == 1 then
    done_var_1 = conversionIndex
  end
  if conversionStep == 2 then
    done_var_1 = valPos
    done_var_2 = conversionIndex
  end
  if conversionStep == 3 then
    done_var_1 = valPos
    done_var_2 = valPos
    done_var_3 = conversionIndex
  end
  if conversionStep == 4 then
    done_var_1 = valPos
    done_var_2 = valPos
    done_var_3 = valPos
    done_var_4 = conversionIndex
  end
  local y = 85
  local dy = 25
  lcd.drawText(5, y, "Parsing Var 1: ", TEXT_COLOR)
  drawProgress(y, done_var_1, valPos)
  y = y + dy
  lcd.drawText(5, y, "Parsing Var 2: ", TEXT_COLOR)
  drawProgress(y, done_var_2, valPos)
  y = y + dy
  lcd.drawText(5, y, "Parsing Var 3: ", TEXT_COLOR)
  drawProgress(y, done_var_3, valPos)
  y = y + dy
  lcd.drawText(5, y, "Parsing Var 4: ", TEXT_COLOR)
  drawProgress(y, done_var_4, valPos)

end

local function state_READ_FILE_DATA_refresh(event, touchState)
  if event == EVT_VIRTUAL_EXIT or event == EVT_VIRTUAL_PREV_PAGE then
    state = STATE.SELECT_SENSORS_INIT
    return 0
  end

  display_read_data(0, 0)

  if collectData(hFile) then
    conversionStep = 0
    state = STATE.PARSE_DATA
  end

  return 0
end

local function state_PARSE_DATA_refresh(event, touchState)
  if event == EVT_VIRTUAL_EXIT then
    return 2

  elseif event == EVT_VIRTUAL_EXIT or event == EVT_VIRTUAL_PREV_PAGE then
    state = STATE.SELECT_SENSORS_INIT
    return 0
  end

  display_read_data(conversionStep, conversionIndex)

  --lcd.drawText(5,110, "Parsing data", TEXT_COLOR)
  --lcd.drawText(5,120, "Almost ready :)", TEXT_COLOR)

  --if conversionStep ~= 0 then
  --    lcd.drawText(5, 80, "Parsing Var " .. conversionStep, TEXT_COLOR)
  --    drawProgress(120, conversionIndex, valPos)
  --end

  local cnt = 0
  if conversionStep == 0 then
    conversionStep = 1
    conversionIndex = 0

    graphTimeBase = valPos / (getTotalSeconds(current_session.endTime) - getTotalSeconds(current_session.startTime))

    for varIndex = 1, 4, 1 do
      if sensorSelection[varIndex].value ~= 0 then
        local columnName = columns[sensorSelection[varIndex].value + 1]
        local i = string.find(columnName, "%(")

        if i ~= nil then
          columnName = string.sub(columnName, 0, i - 1)
        end

        points[varIndex] = { min = 9999, max = -9999, minpos = 0, maxpos = 0, points = {}, name = columnName }
      end
    end
  else
    if sensorSelection[conversionStep].value ~= 0 then
      for i = conversionIndex, valPos - 1, 1 do

        val = tonumber(values[conversionStep][i])
        values[conversionStep][i] = val
        conversionIndex = conversionIndex + 1
        cnt = cnt + 1

        log1("conversionStep: %s", conversionStep)
        log2("points[%d] = %s", conversionStep, points[conversionStep])
        --log2("points[0].max: %s", points[0].max)
        log2("points[].max: %s", points[conversionStep].max)
        if val > points[conversionStep].max then
          points[conversionStep].max = val
          points[conversionStep].maxpos = i
        elseif val < points[conversionStep].min then
          points[conversionStep].min = val
          points[conversionStep].minpos = i
        end

        if cnt > 100 then
          return 0
        end
      end
    end

    if conversionStep == 4 then
      graphStart = 0
      graphSize = valPos
      cursor = 0
      graphMode = GRAPH_CURSOR
      state = STATE.SHOW_GRAPH
    else
      conversionIndex = 0
      conversionStep = conversionStep + 1
    end
  end

  return 0
end

local function run_GRAPH_Adjust(amount, mode)
  if mode == GRAPH_CURSOR then
    cursor = cursor + math.floor(amount)
    if cursor > 100 then
      cursor = 100
    elseif cursor < 0 then
      cursor = 0
    end
  elseif mode == GRAPH_ZOOM then
    if amount > 4 then
      amount = 4
    elseif amount < -4 then
      amount = -4
    end

    local oldgraphSize = graphSize
    graphSize = math.floor(graphSize / (1 + (amount * 0.2)))

    if graphSize < 101 then
      graphSize = 101
    elseif graphSize > valPos then
      graphSize = valPos
    end

    if graphSize > (valPos - graphStart) then
      if amount > 0 then
        graphSize = valPos - graphStart
      else
        graphStart = valPos - graphSize
      end
    else
      local delta = oldgraphSize - graphSize
      graphStart = graphStart + math_floor((delta * (cursor / 100)))

      if graphStart < 0 then
        graphStart = 0
      elseif graphStart + graphSize > valPos then
        graphStart = valPos - graphSize
      end
    end

    graphSize = math_floor(graphSize)

    for varIndex = 1, 4, 1 do
      if sensorSelection[varIndex].value ~= 0 then
        points[varIndex].points = {}
      end
    end
  elseif mode == GRAPH_MINMAX then
    local point = points[(math.floor(graphMinMaxIndex / 2)) + 1]

    local delta = math.floor((point.max - point.min) / 50 * amount)

    if amount > 0 and delta < 1 then
      delta = 1
    elseif amount < 0 and delta > -1 then
      delta = -1
    end

    if graphMinMaxIndex % 2 == 0 then
      point.max = point.max + delta

      if point.max < point.min then
        point.max = point.min + 1
      end
    else
      point.min = point.min + delta

      if point.min > point.max then
        point.min = point.max - 1
      end
    end
  elseif mode == GRAPH_SCROLL then
    graphStart = graphStart + math.floor(((graphSize / 10) * amount))

    if graphStart + graphSize > valPos then
      graphStart = valPos - graphSize
    elseif graphStart < 0 then
      graphStart = 0
    end

    graphStart = math_floor(graphStart)

    for varIndex = 1, 4, 1 do
      if sensorSelection[varIndex].value ~= 0 then
        points[varIndex].points = {}
      end
    end
  end
end

local function state_SHOW_GRAPH_refresh(event, touchState)
  if event == EVT_VIRTUAL_EXIT or event == EVT_VIRTUAL_PREV_PAGE then
    state = STATE.SELECT_SENSORS_INIT
    return 0
  end

  if graphMode == GRAPH_MINMAX and event == EVT_PAGEDN_FIRST then
    graphMinMaxIndex = graphMinMaxIndex + 1

    if graphMinMaxIndex == 8 then
      graphMinMaxIndex = 0
    end

    if graphMinMaxIndex == 2 and sensorSelection[2].value == 0 then
      graphMinMaxIndex = 4
    end

    if graphMinMaxIndex == 4 and sensorSelection[3].value == 0 then
      graphMinMaxIndex = 6
    end

    if graphMinMaxIndex == 6 and sensorSelection[4].value == 0 then
      graphMinMaxIndex = 0
    end

    if graphMinMaxIndex == 0 and sensorSelection[1].value == 0 then
      graphMinMaxIndex = 2
    end
  elseif graphMode == GRAPH_MINMAX and event == EVT_PAGEUP_FIRST then
    graphMinMaxIndex = graphMinMaxIndex - 1

    if graphMinMaxIndex < 0 then
      graphMinMaxIndex = 7
    end

    if graphMinMaxIndex == 7 and sensorSelection[4].value == 0 then
      graphMinMaxIndex = 5
    end

    if graphMinMaxIndex == 5 and sensorSelection[3].value == 0 then
      graphMinMaxIndex = 3
    end

    if graphMinMaxIndex == 3 and sensorSelection[2].value == 0 then
      graphMinMaxIndex = 1
    end

    if graphMinMaxIndex == 1 and sensorSelection[1].value == 0 then
      graphMinMaxIndex = 7
    end
    --elseif event == EVT_ENTER_BREAK or event == EVT_ROT_BREAK then
  elseif event == EVT_VIRTUAL_ENTER or event == EVT_ROT_BREAK then
    if graphMode == GRAPH_CURSOR then
      graphMode = GRAPH_ZOOM
    elseif graphMode == GRAPH_ZOOM then
      graphMode = GRAPH_SCROLL
    elseif graphMode == GRAPH_SCROLL then
      graphMode = GRAPH_MINMAX
    else
      graphMode = GRAPH_CURSOR
    end
  elseif event == EVT_PLUS_FIRST or event == EVT_ROT_RIGHT or event == EVT_PLUS_REPT then
    run_GRAPH_Adjust(1, graphMode)
  elseif event == EVT_MINUS_FIRST or event == EVT_ROT_LEFT or event == EVT_MINUS_REPT then
    run_GRAPH_Adjust(-1, graphMode)
  end

  if event == EVT_TOUCH_SLIDE then
    log("EVT_TOUCH_SLIDE")
    log2("EVT_TOUCH_SLIDE, startX:%d   x:%d", touchState.startX, touchState.x)
    log2("EVT_TOUCH_SLIDE, startY:%d   y:%d", touchState.startY, touchState.y)
    local dx = touchState.startX - touchState.x
    local adjust = math.floor(dx / 100)
    log2("EVT_TOUCH_SLIDE, dx:%d,   adjust:%d", dx, adjust)
    run_GRAPH_Adjust(adjust, GRAPH_SCROLL)
  end

  local adjust = getValue('ail') / 200
  if math.abs(adjust) > 0.5 then
    if graphMode == GRAPH_MINMAX then
      run_GRAPH_Adjust(adjust, GRAPH_MINMAX)
    else
      run_GRAPH_Adjust(adjust, GRAPH_SCROLL)
    end
  end

  adjust = getValue('ele') / 200
  if math.abs(adjust) > 0.5 then
    run_GRAPH_Adjust(adjust, GRAPH_ZOOM)
  end

  --adjust = getValue('jsy') / 200
  --if math.abs(adjust) > 0.5 then
  --    run_GRAPH_Adjust(adjust, GRAPH_ZOOM)
  --end

  adjust = getValue('rud') / 200
  if math.abs(adjust) > 0.5 then
    run_GRAPH_Adjust(adjust, GRAPH_CURSOR)
  end

  --adjust = getValue('jsx') / 200
  --if math.abs(adjust) > 0.5 then
  --    run_GRAPH_Adjust(adjust, GRAPH_SCROLL)
  --end


  drawGraph()
  return 0
end

local function run(event, touchState)
  if event == nil then
    error("Cannot be run as a model script!")
    return 2
  end

  --log("run() ---------------------------")
  --log1("event: %s", event)

  --if event == EVT_TOUCH_SLIDE then
  --    log("EVT_TOUCH_SLIDE")
  --    log2("EVT_TOUCH_SLIDE, startX:%d   x:%d", touchState.startX, touchState.x)
  --    log2("EVT_TOUCH_SLIDE, startY:%d   y:%d", touchState.startY, touchState.y)
  --    local d = math.floor((touchState.startY - touchState.y) / 20 + 0.5)
  --end

  drawMain()

  if state == STATE.SELECT_NA then
    state = STATE.SELECT_FILE_INIT
    return 0
  end

  if state == STATE.SELECT_FILE_INIT then
    return state_SELECT_FILE_init(event, touchState)
  elseif state == STATE.SELECT_FILE then
    return state_SELECT_FILE_refresh(event, touchState)
  elseif state == STATE.READ_FILE_HEADER then
    return state_READ_FILE_HEADER_refresh(event, touchState)
  elseif state == STATE.SELECT_SENSORS_INIT then
    return state_SELECT_SENSORS_INIT(event, touchState)
  elseif state == STATE.SELECT_SENSORS then
    return state_SELECT_SENSORS_refresh(event, touchState)
  elseif state == STATE.READ_FILE_DATA then
    return state_READ_FILE_DATA_refresh(event, touchState)
  elseif state == STATE.PARSE_DATA then
    return state_PARSE_DATA_refresh(event, touchState)
  elseif state == STATE.SHOW_GRAPH then
    return state_SHOW_GRAPH_refresh(event, touchState)
  end

  --impossible state
  error("Something went wrong with the script!")
  return 2
end

return { init = init, run = run }
