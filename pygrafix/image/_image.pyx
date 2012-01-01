from pygrafix.c_headers.gl cimport *

import math

# this has to be a from module import ***, because pygrafix.image is not defined yet
from pygrafix import window
from pygrafix.image import codecs

def get_next_pot(n):
    return 2 ** (n - 1).bit_length()

cdef class ImageData:
    cdef public bytes data
    cdef public int width
    cdef public int height
    cdef public str format

    def __init__(self, width, height, format, data):
        self.width = width
        self.height = height
        self.format = format
        self.data = data

# ugly counter hack to make each texture unique
_texture_id = 0

cdef class Texture:
    cdef int _smoothing
    cdef int _id
    cdef ImageData imgdata
    cdef readonly int width
    cdef readonly int height

    property target:
        def __get__(self):
            cur_window = window.get_current_window()

            if not cur_window:
                raise Exception("No opened window")

            if not self._id in cur_window._textures:
                self._upload_texture()

            return cur_window._textures[self._id][0]

    property id:
        def __get__(self):
            cur_window = window.get_current_window()

            if not self._id in cur_window._textures:
                self._upload_texture()

            if not cur_window:
                raise Exception("No opened window")

            return cur_window._textures[self._id][1]

    def __init__(self, imgdata):
        global _texture_id
        self._id = _texture_id
        _texture_id += 1

        self.imgdata = imgdata
        self.width = imgdata.width
        self.height = imgdata.height
        self._smoothing = 0

    def copy(self):
        new = Texture(self.imgdata)
        new.set_scale_smoothing(self._smoothing)
        return new

    def set_scale_smoothing(self, int smoothing):
        self._smoothing = smoothing

        cur_window = window.get_current_window()

        if cur_window and self._id in cur_window._textures:
            if self._smoothing == 2:
                flag = GL_NICEST
            elif self._smoothing == 1:
                flag = GL_LINEAR
            else:
                flag = GL_NEAREST

            target, tex_id = cur_window._textures[self._id]
            glBindTexture(target, tex_id)
            glTexParameteri(target, GL_TEXTURE_MIN_FILTER, flag)
            glTexParameteri(target, GL_TEXTURE_MAG_FILTER, flag)

    def _upload_texture(self):
        cur_window = window.get_current_window()

        if not cur_window:
            raise Exception("No opened window")

        if len(self.imgdata.format) == 4:
            oglformat = GL_RGBA
        elif len(self.imgdata.format) == 3:
            oglformat = GL_RGB
        elif len(self.imgdata.format) == 2:
            oglformat = GL_LUMINANCE_ALPHA
        elif len(self.imgdata.fornat) == 1:
            oglformat = GL_LUMINANCE
        else:
            raise Exception("Unknown data format")

        # do we have rectangle support?
        if "GL_ARB_texture_rectangle" in cur_window._gl_extensions:
            target = GL_TEXTURE_RECTANGLE_ARB
        else:
            target = GL_TEXTURE_2D

            # if we don't use rectangle we must watch out for POT
            if not "GL_ARB_texture_non_power_of_two" in cur_window._gl_extensions:
                # if our width is not a power of two we must convert it
                if self.imgdata.width != get_next_pot(self.imgdata.width):
                    old_pitch = self.imgdata.width * len(self.imgdata.format)
                    old_size = old_pitch * self.imgdata.height

                    transparent_columns = (b"\0" * len(self.imgdata.format)) * (get_next_pot(self.imgdata.width) - self.imgdata.width)

                    self.imgdata.data = b"".join(self.imgdata.data[i:i + old_pitch] + transparent_columns for i in range(0, old_size, old_pitch))
                    self.imgdata.width = get_next_pot(self.imgdata.width)

                # same goes for our height
                if self.imgdata.height != get_next_pot(self.imgdata.height):
                    transparent_row = (b"\0" * len(self.imgdata.format)) * self.imgdata.width

                    self.imgdata.data += transparent_row * (get_next_pot(self.imgdata.height) - self.imgdata.height)
                    self.imgdata.height = get_next_pot(self.imgdata.height)

        # generate texture id
        cdef GLuint tex_id
        glGenTextures(1, &tex_id)

        if not tex_id:
            raise Exception("Error while creating texture")

        glBindTexture(target, tex_id)
        glTexImage2D(target, 0, oglformat, self.imgdata.width, self.imgdata.height, 0, oglformat, GL_UNSIGNED_BYTE, <char *> self.imgdata.data)

        cur_window._textures[self._id] = (target, tex_id)

        # update texture's settings
        self.set_scale_smoothing(self._smoothing)

    def __del__(self):
        cdef GLuint tex_id
        cur_window = window.get_current_window()

        if cur_window and self._id in cur_window._textures:
            target, tex_id = cur_window._textures[self._id]

            glDeleteTextures(1, &tex_id)
            del cur_window._textures[self._id]


def load(filename, file = None, decoder = None, ):
    if file == None:
        file = open(filename, "rb")

    # if an explicit decoder was specified we will only try that one
    if decoder:
        return decoder.decode(file, filename)

    # otherwise decode it using all possible means
    error = codecs.ImageDecodeException("No codecs found")
    for decoder in codecs.get_decoders(filename):
        try:
            imgdata = decoder.decode(file, filename)
            return Texture(imgdata)
        except codecs.ImageDecodeException as e:
            error = e
            file.seek(0)

    raise error