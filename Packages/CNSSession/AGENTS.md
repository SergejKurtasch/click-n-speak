# CNSSession Guide

`CNSSession` owns the recording → draft → editable popup → delivery state
machine. Recording, file transcription, injection, reload, runtime mutation,
warmup, and shutdown must respect activity ownership; shutdown is terminal.

Capture draft inputs at activity start. Delivery must return typed outcomes:
missing focus copies and notifies but remains failure, injection failure
reopens the draft, and cancellation adds no new side effect.
