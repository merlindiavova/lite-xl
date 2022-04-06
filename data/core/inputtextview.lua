local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local translate = require "core.doc.translate"
local View = require "core.view"


local InputTextView = View:extend()

InputTextView.context = "session"

local function move_to_line_offset(dv, line, col, offset)
  local xo = dv.last_x_offset
  if xo.line ~= line or xo.col ~= col then
    xo.offset = dv:get_col_x_offset(line, col)
  end
  xo.line = line + offset
  xo.col = dv:get_x_offset_col(line + offset, xo.offset)
  return xo.line, xo.col
end


InputTextView.translate = {
  ["previous_page"] = function(doc, line, col, dv)
    local min, max = dv:get_visible_line_range()
    return line - (max - min), 1
  end,

  ["next_page"] = function(doc, line, col, dv)
    local min, max = dv:get_visible_line_range()
    return line + (max - min), 1
  end,

  ["previous_line"] = function(doc, line, col, dv)
    if line == 1 then
      return 1, 1
    end
    return move_to_line_offset(dv, line, col, -1)
  end,

  ["next_line"] = function(doc, line, col, dv)
    if line == #doc.lines then
      return #doc.lines, math.huge
    end
    return move_to_line_offset(dv, line, col, 1)
  end,
}


function InputTextView:new(doc)
  InputTextView.super.new(self)
  self.cursor = "ibeam"
  self.scrollable = true
  self.doc = assert(doc)
  self.last_x_offset = {}
end


function InputTextView:get_scrollable_size()
  return self:get_line_height() * (#self.doc.lines) + style.padding.y * 2
end


function InputTextView:get_font()
  return style.code_font
end


function InputTextView:get_line_height()
  return math.floor(self:get_font():get_height() * config.line_height)
end


function InputTextView:get_line_screen_position(idx)
  local x, y = self:get_content_offset()
  local lh = self:get_line_height()
  return x, y + (idx-1) * lh + style.padding.y
end


function InputTextView:get_line_text_y_offset()
  local lh = self:get_line_height()
  local th = self:get_font():get_height()
  return (lh - th) / 2
end


function InputTextView:get_visible_line_range()
  local x, y, x2, y2 = self:get_content_bounds()
  local lh = self:get_line_height()
  local minline = math.max(1, math.floor(y / lh))
  local maxline = math.min(#self.doc.lines, math.floor(y2 / lh) + 1)
  return minline, maxline
end


function InputTextView:get_col_x_offset(line, col)
  local default_font = self:get_font()
  local column = 1
  local xoffset = 0
  for _, type, text in self.doc.highlighter:each_token(line) do
    local font = style.syntax_fonts[type] or default_font
    for char in common.utf8_chars(text) do
      if column == col then
        return xoffset / font:subpixel_scale()
      end
      xoffset = xoffset + font:get_width_subpixel(char)
      column = column + #char
    end
  end

  return xoffset / default_font:subpixel_scale()
end


function InputTextView:get_x_offset_col(line, x)
  local line_text = self.doc.lines[line]

  local xoffset, last_i, i = 0, 1, 1
  local default_font = self:get_font()
  local subpixel_scale = default_font:subpixel_scale()
  local x_subpixel = subpixel_scale * x + subpixel_scale / 2
  for _, type, text in self.doc.highlighter:each_token(line) do
    local font = style.syntax_fonts[type] or default_font
    for char in common.utf8_chars(text) do
      local w = font:get_width_subpixel(char)
      if xoffset >= subpixel_scale * x then
        return (xoffset - x_subpixel > w / 2) and last_i or i
      end
      xoffset = xoffset + w
      last_i = i
      i = i + #char
    end
  end

  return #line_text
end


function InputTextView:resolve_screen_position(x, y)
  local ox, oy = self:get_line_screen_position(1)
  local line = math.floor((y - oy) / self:get_line_height()) + 1
  line = common.clamp(line, 1, #self.doc.lines)
  local col = self:get_x_offset_col(line, x - ox)
  return line, col
end


function InputTextView:scroll_to_line(line, ignore_if_visible, instant)
  local min, max = self:get_visible_line_range()
  if not (ignore_if_visible and line > min and line < max) then
    local lh = self:get_line_height()
    self.scroll.to.y = math.max(0, lh * (line - 1) - self.size.y / 2)
    if instant then
      self.scroll.y = self.scroll.to.y
    end
  end
end


function InputTextView:scroll_to_make_visible(line, col)
  local min = self:get_line_height() * (line - 1)
  local max = self:get_line_height() * (line + 2) - self.size.y
  self.scroll.to.y = math.min(self.scroll.to.y, min)
  self.scroll.to.y = math.max(self.scroll.to.y, max)
  local xoffset = self:get_col_x_offset(line, col)
  local xmargin = 3 * self:get_font():get_width(' ')
  local xsup = xoffset + xmargin
  local xinf = xoffset - xmargin
  if xsup > self.scroll.x + self.size.x then
    self.scroll.to.x = xsup - self.size.x
  elseif xinf < self.scroll.x then
    self.scroll.to.x = math.max(0, xinf)
  end
end


local function mouse_selection(doc, clicks, line1, col1, line2, col2)
  local swap = line2 < line1 or line2 == line1 and col2 <= col1
  if swap then
    line1, col1, line2, col2 = line2, col2, line1, col1
  end
  if clicks % 4 == 2 then
    line1, col1 = translate.start_of_word(doc, line1, col1)
    line2, col2 = translate.end_of_word(doc, line2, col2)
  elseif clicks % 4 == 3 then
    if line2 == #doc.lines and doc.lines[#doc.lines] ~= "\n" then
      doc:insert(math.huge, math.huge, "\n")
    end
    line1, col1, line2, col2 = line1, 1, line2 + 1, 1
  end
  if swap then
    return line2, col2, line1, col1
  end
  return line1, col1, line2, col2
end


function InputTextView:on_mouse_pressed(button, x, y, clicks)
  local caught = InputTextView.super.on_mouse_pressed(self, button, x, y, clicks)
  if caught then
    return
  end
  if keymap.modkeys["shift"] then
    if clicks % 2 == 1 then
      local line1, col1 = select(3, self.doc:get_selection())
      local line2, col2 = self:resolve_screen_position(x, y)
      self.doc:set_selection(line2, col2, line1, col1)
    end
  else
    local line, col = self:resolve_screen_position(x, y)
    if keymap.modkeys["ctrl"] then
      self.doc:add_selection(mouse_selection(self.doc, clicks, line, col, line, col))
    else
      self.doc:set_selection(mouse_selection(self.doc, clicks, line, col, line, col))
    end
    self.mouse_selecting = { line, col, clicks = clicks }
  end
  core.blink_reset()
end


function InputTextView:on_mouse_moved(x, y, ...)
  InputTextView.super.on_mouse_moved(self, x, y, ...)

  if self:scrollbar_overlaps_point(x, y) or self.dragging_scrollbar then
    self.cursor = "arrow"
  else
    self.cursor = "ibeam"
  end

  if self.mouse_selecting then
    local l1, c1 = self:resolve_screen_position(x, y)
    local l2, c2 = table.unpack(self.mouse_selecting)
    local clicks = self.mouse_selecting.clicks
    if keymap.modkeys["ctrl"] then
      if l1 > l2 then l1, l2 = l2, l1 end
      self.doc.selections = { }
      for i = l1, l2 do
        self.doc:set_selections(i - l1 + 1, i, math.min(c1, #self.doc.lines[i]), i, math.min(c2, #self.doc.lines[i]))
      end
    else
      self.doc:set_selection(mouse_selection(self.doc, clicks, l1, c1, l2, c2))
    end
  end
end


function InputTextView:on_mouse_released(button)
  InputTextView.super.on_mouse_released(self, button)
  self.mouse_selecting = nil
end


function InputTextView:on_text_input(text)
  self.doc:text_input(text)
end


function InputTextView:update()
  -- scroll to make caret visible and reset blink timer if it moved
  local line, col = self.doc:get_selection()
  if (line ~= self.last_line or col ~= self.last_col) and self.size.x > 0 then
    if core.active_view == self then
      self:scroll_to_make_visible(line, col)
    end
    core.blink_reset()
    self.last_line, self.last_col = line, col
  end

  -- update blink timer
  if self == core.active_view and not self.mouse_selecting then
    local T, t0 = config.blink_period, core.blink_start
    local ta, tb = core.blink_timer, system.get_time()
    if ((tb - t0) % T < T / 2) ~= ((ta - t0) % T < T / 2) then
      core.redraw = true
    end
    core.blink_timer = tb
  end

  InputTextView.super.update(self)
end


function InputTextView:draw_line_highlight(x, y)
  local lh = self:get_line_height()
  renderer.draw_rect(x, y, self.size.x, lh, style.line_highlight)
end


function InputTextView:draw_line_text(idx, x, y)
  local default_font = self:get_font()
  local subpixel_scale = default_font:subpixel_scale()
  local tx, ty = subpixel_scale * x, y + self:get_line_text_y_offset()
  for _, type, text in self.doc.highlighter:each_token(idx) do
    local color = style.syntax[type]
    local font = style.syntax_fonts[type] or default_font
    if config.draw_whitespace then
      tx = renderer.draw_text_subpixel(font, text, tx, ty, color, core.replacements, style.syntax.comment)
    else
      tx = renderer.draw_text_subpixel(font, text, tx, ty, color)
    end
  end
end

function InputTextView:draw_caret(x, y)
    local lh = self:get_line_height()
    renderer.draw_rect(x, y, style.caret_width, lh, style.caret)
end

function InputTextView:draw_line_body(idx, x, y)
  -- draw selection if it overlaps this line
  for lidx, line1, col1, line2, col2 in self.doc:get_selections(true) do
    if idx >= line1 and idx <= line2 then
      local text = self.doc.lines[idx]
      if line1 ~= idx then col1 = 1 end
      if line2 ~= idx then col2 = #text + 1 end
      local x1 = x + self:get_col_x_offset(idx, col1)
      local x2 = x + self:get_col_x_offset(idx, col2)
      local lh = self:get_line_height()
      if x1 ~= x2 then
        renderer.draw_rect(x1, y, x2 - x1, lh, style.selection)
      end
    end
  end
  local draw_highlight = nil
  for lidx, line1, col1, line2, col2 in self.doc:get_selections(true) do
    -- draw line highlight if caret is on this line
    if draw_highlight ~= false and config.highlight_current_line
    and line1 == idx and core.active_view == self then
      draw_highlight = (line1 == line2 and col1 == col2)
    end
  end
  if draw_highlight then self:draw_line_highlight(x + self.scroll.x, y) end

  -- draw line's text
  self:draw_line_text(idx, x, y)
end


function InputTextView:draw_overlay()
  if core.active_view == self then
    local minline, maxline = self:get_visible_line_range()
    -- draw caret if it overlaps this line
    local T = config.blink_period
    for _, line, col in self.doc:get_selections() do
      if line >= minline and line <= maxline
      and system.window_has_focus() then
        if config.disable_blink
        or (core.blink_timer - core.blink_start) % T < T / 2 then
          local x, y = self:get_line_screen_position(line)
          self:draw_caret(x + self:get_col_x_offset(line, col), y)
        end
      end
    end
  end
end

function InputTextView:draw()
  self:draw_background(style.background)

  self:get_font():set_tab_size(config.indent_size)

  local minline, maxline = self:get_visible_line_range()
  local lh = self:get_line_height()

  local x, y = self:get_line_screen_position(minline)

  local pos = self.position
  x, y = self:get_line_screen_position(minline)
  for i = minline, maxline do
    self:draw_line_body(i, x, y)
    y = y + lh
  end
  self:draw_overlay()
  self:draw_scrollbar()
end


return InputTextView