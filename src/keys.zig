/// Keys mapped from ANSI codes to Pit keys
pub const Key = enum(u16) {
    arrow_left = 257,
    arrow_right,
    arrow_up,
    arrow_down,
    home,
    end,
    delete,
    insert,
    page_up,
    page_down,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    keypad_1,
    keypad_2,
    keypad_3,
    keypad_4,
    keypad_5,
    keypad_6,
    keypad_7,
    keypad_8,
    keypad_9,
    keypad_0,
    _,

    /// Returns the corresponding `Key` from a character found after an escape sequence
    pub fn fromEscChar(char: u8) Key {
        return switch (char) {
            '1' => .home,
            '2' => .insert,
            '3' => .delete,
            '4' => .end,
            '5' => .page_up,
            '6' => .page_down,
            '7' => .home,
            '8' => .end,
            'A' => .arrow_up,
            'B' => .arrow_down,
            'C' => .arrow_right,
            'D' => .arrow_left,
            'F' => .end,
            'H' => .home,
            else => unreachable,
        };
    }

    /// Returns a `Key` enum from the given char
    pub fn fromChar(char: u8) Key {
        return @intToEnum(Key, char);
    }

    /// Returns the integer value of `Key`
    pub fn int(self: Key) u16 {
        return @enumToInt(self);
    }
};
