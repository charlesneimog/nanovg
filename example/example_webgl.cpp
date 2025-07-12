#include <sstream>
#include <vector>
#include <algorithm>

#include <emscripten.h>
#include <emscripten/bind.h>
#include <emscripten/val.h>
#include <emscripten/webaudio.h>

#include <GLES3/gl3.h>
#define NANOVG_GLES3_IMPLEMENTATION
#include <nanovg.h>
#include <nanovg_gl.h>
#include <nanovg_gl_utils.h>

// ──────────────────────────────────────────
struct Rect {
    float x, y, w, h;
    bool intersects(const Rect &other) const {
        return !(x + w < other.x || other.x + other.w < x || y + h < other.y || other.y + other.h < y);
    }
};

// ──────────────────────────────────────────
struct MovingBox {
    float x, y, w, h;
    float dx, dy;
    NVGcolor color;
    Rect oldRect;
    MovingBox(float x_, float y_, float w_, float h_, float dx_, float dy_, NVGcolor c)
        : x(x_), y(y_), w(w_), h(h_), dx(dx_), dy(dy_), color(c) {
        oldRect = getRect();
    }
    Rect getRect() const {
        return {x, y, w, h};
    }
    void update(float maxw, float maxh) {
        oldRect = getRect();
        x += dx;
        y += dy;
        if (x < 0 || x + w > maxw) {
            dx = -dx;
        }
        if (y < 0 || y + h > maxh) {
            dy = -dy;
        }
        // clamp in bounds
        x = std::max(0.0f, std::min(x, maxw - w));
        y = std::max(0.0f, std::min(y, maxh - h));
    }
    void draw(NVGcontext *vg) {
        nvgBeginPath(vg);
        nvgRect(vg, x, y, w, h);
        nvgFillColor(vg, color);
        nvgFill(vg);
    }
};

// ──────────────────────────────────────────
struct NanoVGExample {
    EMSCRIPTEN_WEBGL_CONTEXT_HANDLE ctx;
    NVGcontext *nvg;
    std::vector<MovingBox> boxes;
    std::vector<Rect> dirtyRects;
    int winWidth = 800;
    int winHeight = 400;
};

// ──────────────────────────────────────────
void clearRectGL(float x, float y, float w, float h, int winH) {
    // OpenGL y=bottom, NanoVG y=top, so flip y
    glEnable(GL_SCISSOR_TEST);
    glScissor((GLint)x, (GLint)(winH - y - h), (GLsizei)w, (GLsizei)h);
    glClearColor(0.18f, 0.18f, 0.18f, 1.0f); // dark background
    glClear(GL_COLOR_BUFFER_BIT);
    glDisable(GL_SCISSOR_TEST);
}

// ──────────────────────────────────────────
void loop(void *userData) {
    NanoVGExample *self = (NanoVGExample *)userData;
    for (auto &box : self->boxes) {
        self->dirtyRects.push_back(box.oldRect);
    }

    // Update and mark new rects dirty
    for (auto &box : self->boxes) {
        box.update(self->winWidth, self->winHeight);
        self->dirtyRects.push_back(box.getRect());
    }

    // Merge dirty rects (simple, not optimal)
    // For demo purposes, just use as-is

    // Clear only dirty rects in GL
    for (const auto &r : self->dirtyRects) {
        clearRectGL(r.x, r.y, r.w, r.h, self->winHeight);
    }

    nvgBeginFrame(self->nvg, self->winWidth, self->winHeight, 1.0f);

    // Draw only boxes intersecting any dirty rect
    for (auto &box : self->boxes) {
        Rect rect = box.getRect();
        bool needsDraw = false;
        for (const auto &dr : self->dirtyRects) {
            if (rect.intersects(dr)) {
                needsDraw = true;
                break;
            }
        }
        if (needsDraw) {
            box.draw(self->nvg);
        }
    }

    nvgEndFrame(self->nvg);

    self->dirtyRects.clear();
}

int main() {
    EmscriptenWebGLContextAttributes attr;
    emscripten_webgl_init_context_attributes(&attr);
    attr.alpha = false;
    attr.depth = true;
    attr.stencil = false;
    attr.antialias = false;
    attr.majorVersion = 2;
    attr.minorVersion = 0;

    NanoVGExample *ud = new NanoVGExample();
    ud->winWidth = 800;
    ud->winHeight = 400;

    ud->ctx = emscripten_webgl_create_context("#canvas", &attr);
    if (ud->ctx <= 0) {
        return -1;
    }
    emscripten_webgl_make_context_current(ud->ctx);
    ud->nvg = nvgCreateContext(0);
    if (!ud->nvg) {
        fprintf(stderr, "Failed to create NVG context\n");
        emscripten_webgl_destroy_context(ud->ctx);
        return -1;
    }

    // Create some moving boxes
    ud->boxes.push_back(MovingBox(100, 80, 50, 50, 2, 1.5, nvgRGB(227, 51, 51)));
    ud->boxes.push_back(MovingBox(250, 130, 60, 60, -1.5, 2.2, nvgRGB(51, 227, 51)));
    ud->boxes.push_back(MovingBox(500, 200, 40, 40, 2.3, -2.4, nvgRGB(51, 51, 227)));

    // Initial clear
    glClearColor(0.18f, 0.18f, 0.18f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);

    emscripten_set_main_loop_arg(loop, ud, 0, 0);

    return 0;
}
