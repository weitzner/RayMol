// PyMOLBridge.h — C bridging header for Swift ↔ PyMOL embedding API
// This header exposes the C functions Swift needs to drive PyMOL.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>

// Opaque PyMOL instance
typedef struct _CPyMOL CPyMOL;

// --- Lifecycle ---
CPyMOL *PyMOLBridge_New(void);
void PyMOLBridge_Free(CPyMOL *instance);
void PyMOLBridge_InitPython(CPyMOL *instance, const char *resourcePath);
void PyMOLBridge_Start(CPyMOL *instance);
void PyMOLBridge_Stop(CPyMOL *instance);

// --- Render loop ---
int  PyMOLBridge_Idle(CPyMOL *instance);
void PyMOLBridge_Draw(CPyMOL *instance);
void PyMOLBridge_Reshape(CPyMOL *instance, int width, int height);
int  PyMOLBridge_GetRedisplay(CPyMOL *instance, int reset);

// --- Input ---
void PyMOLBridge_Button(CPyMOL *instance, int button, int state, int x, int y, int modifiers);
void PyMOLBridge_Drag(CPyMOL *instance, int x, int y, int modifiers);
void PyMOLBridge_Key(CPyMOL *instance, unsigned char k, int x, int y, int modifiers);

// --- Context management ---
void PyMOLBridge_PushValidContext(CPyMOL *instance);
void PyMOLBridge_PopValidContext(CPyMOL *instance);

// --- Python execution ---
void PyMOLBridge_RunCommand(const char *command);
char *PyMOLBridge_GetFeedback(CPyMOL *instance);
void PyMOLBridge_FreeFeedback(char *str);

// --- Metal rendering ---
void PyMOLBridge_RenderMetal(CPyMOL *instance);

// --- Getters ---
void *PyMOLBridge_GetGlobals(CPyMOL *instance);
void *PyMOLBridge_GetRenderer(CPyMOL *instance);

// --- Button/modifier constants (match PyMOL's defines) ---
#define PYMOL_BUTTON_LEFT    0
#define PYMOL_BUTTON_MIDDLE  1
#define PYMOL_BUTTON_RIGHT   2
#define PYMOL_BUTTON_SCROLL_FORWARD 3
#define PYMOL_BUTTON_SCROLL_REVERSE 4
#define PYMOL_BUTTON_DOWN    0
#define PYMOL_BUTTON_UP      1

#define PYMOL_MOD_SHIFT  1
#define PYMOL_MOD_CTRL   2
#define PYMOL_MOD_ALT    4

#ifdef __cplusplus
}
#endif
