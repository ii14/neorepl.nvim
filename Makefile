LUA     = luajit
CFLAGS += $(shell pkg-config --cflags $(LUA))

TARGET  = lua/nrepl/debug/debugger.so

all: $(TARGET)

$(TARGET): src/debugger.c
	$(CC) $(CFLAGS) -Ideps/luajit-2.0/src -fPIC -shared -o $@ $< $(LDFLAGS)

luajit-2.0:
	mkdir -p deps
	git clone https://github.com/LuaJIT/LuaJIT deps/luajit-2.0 -b v2.0 --depth 1

clean:
	rm -f $(TARGET)

distclean:
	rm -rf deps $(TARGET)

.PHONY: all test clean distclean luajit-2.0
