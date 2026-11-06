---
title: Making a video from images
category: Importing
summary: Turn a folder of numbered images into a video, or use a photo as a still clip.
order: 1
---

SwiftCut can make a source video from images, such as frames from a render, a time-lapse, or stop motion.

## Importing

- **Drag** a folder of images, or some images, from Finder onto the window. SwiftCut asks whether to import them as an **Image Sequence** (one video, one image per frame) or as **Individual Images** (each image its own still clip).
- Or choose **File › Import Image Sequence…** (⌥⇧⌘I) and pick a folder or images.

Images play in name order, with numbers compared the way Finder does, so `frame2` comes before `frame10`. Each folder becomes its own video.

## Settings

Select the clip in the sidebar. The inspector's **Image Sequence** section (or **Still Image**, for one image) has:

- **Frame Size**: Match Images uses the first image's size. Pick a common size, or Custom to type a width and height.
- **Fit**: how images of a different shape fill the frame, with black bars or cropped edges.
- **Frame Rate**: how many images play each second. Pick a common rate, or Custom to type any rate.
- **Duration**: for a still image, how long it shows.

SwiftCut makes a ProRes video from the images and keeps it in its cache. Changing a setting makes it again; the old one plays until the new one is ready. Images with transparency keep it (ProRes 4444).

The project remembers the images, not the video, so keep the images where they are.
