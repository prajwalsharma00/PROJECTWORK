# 📝 Flutter Todo App with C Backend Integration

This is a **cross-platform Todo List Flutter app** that connects to a **custom-built C backend** over TCP sockets using a **custom protocol**. It's designed to be lightweight, offline-capable, and powerful — perfect for students, developers, or anyone learning how to connect native C applications with modern UI frameworks.

---

## 💡 What Is This App?

This app helps you:

- ✅ Track your **daily tasks**
- ⏳ See your **past completed tasks**
- 📅 Schedule **future tasks**
- 🧠 Prioritize tasks (High, Medium, Low)
- 📡 Communicate with a **C server backend** over sockets in real time

All task data is stored in a CSV file on the server side and updated live via socket communication.

---

## 🔧 How It Works (Architecture)

```text
┌─────────────┐          TCP Socket          ┌────────────────────┐
│ Flutter App │ ───────────────────────────▶ │  C Server Backend   │
└─────────────┘    (Custom Protocol)         └────────────────────┘
                          ▲
                          │
                   Reads/Writes CSV
