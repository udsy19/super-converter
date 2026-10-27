import Foundation

/// Glyph names from the CFF standard strings (SIDs 0...228, the ISOAdobe character set) and from the Macintosh standard
/// glyph order that `post` format 1 and 2 index (258 names).
enum GlyphNameTables {
    private static let latinTail = """
    exclamdown cent sterling fraction yen florin section currency quotesingle quotedblleft guillemotleft guilsinglleft \
    guilsinglright fi fl endash dagger daggerdbl periodcentered paragraph bullet quotesinglbase quotedblbase quotedblright \
    guillemotright ellipsis perthousand questiondown grave acute circumflex tilde macron breve dotaccent dieresis ring \
    cedilla hungarumlaut ogonek caron emdash AE ordfeminine Lslash Oslash OE ordmasculine ae dotlessi lslash oslash oe \
    germandbls onesuperior logicalnot mu trademark Eth onehalf plusminus Thorn onequarter divide brokenbar degree thorn \
    threequarters twosuperior registered minus eth multiply threesuperior copyright Aacute Acircumflex Adieresis Agrave \
    Aring Atilde Ccedilla Eacute Ecircumflex Edieresis Egrave Iacute Icircumflex Idieresis Igrave Ntilde Oacute \
    Ocircumflex Odieresis Ograve Otilde Scaron Uacute Ucircumflex Udieresis Ugrave Yacute Ydieresis Zcaron aacute \
    acircumflex adieresis agrave aring atilde ccedilla eacute ecircumflex edieresis egrave iacute icircumflex idieresis \
    igrave ntilde oacute ocircumflex odieresis ograve otilde scaron uacute ucircumflex udieresis ugrave yacute ydieresis \
    zcaron
    """

    private static let asciiNames: [String] = {
        let low = """
        space exclam quotedbl numbersign dollar percent ampersand quotesingle parenleft parenright asterisk plus comma \
        hyphen period slash zero one two three four five six seven eight nine colon semicolon less equal greater question \
        at A B C D E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft backslash bracketright asciicircum underscore \
        grave a b c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar braceright asciitilde
        """
        return low.split(separator: " ").map(String.init)
    }()

    /// SID 0...228.
    static let cffStandard: [String] = {
        var names = [".notdef"]
        var ascii = asciiNames
        ascii[ascii.firstIndex(of: "quotesingle")!] = "quoteright"
        ascii[ascii.firstIndex(of: "grave")!] = "quoteleft"
        names += ascii
        names += latinTail.split(separator: " ").map(String.init)
        return names
    }()

    /// The Macintosh standard order (258 names).
    static let macStandard: [String] = {
        var names = [".notdef", ".null", "nonmarkingreturn"] + asciiNames
        names += """
        Adieresis Aring Ccedilla Eacute Ntilde Odieresis Udieresis aacute agrave acircumflex adieresis atilde aring \
        ccedilla eacute egrave ecircumflex edieresis iacute igrave icircumflex idieresis ntilde oacute ograve ocircumflex \
        odieresis otilde uacute ugrave ucircumflex udieresis dagger degree cent sterling section bullet paragraph \
        germandbls registered copyright trademark acute dieresis notequal AE Oslash infinity plusminus lessequal \
        greaterequal yen mu partialdiff summation product pi integral ordfeminine ordmasculine Omega ae oslash \
        questiondown exclamdown logicalnot radical florin approxequal Delta guillemotleft guillemotright ellipsis \
        nonbreakingspace Agrave Atilde Otilde OE oe endash emdash quotedblleft quotedblright quoteleft quoteright divide \
        lozenge ydieresis Ydieresis fraction currency guilsinglleft guilsinglright fi fl daggerdbl periodcentered \
        quotesinglbase quotedblbase perthousand Acircumflex Ecircumflex Aacute Edieresis Egrave Iacute Icircumflex \
        Idieresis Igrave Oacute Ocircumflex apple Ograve Uacute Ucircumflex Ugrave dotlessi circumflex tilde macron breve \
        dotaccent ring cedilla hungarumlaut ogonek caron Lslash lslash Scaron scaron Zcaron zcaron brokenbar Eth eth \
        Yacute yacute Thorn thorn minus multiply onesuperior twosuperior threesuperior onehalf onequarter threequarters \
        franc Gbreve gbreve Idotaccent Scedilla scedilla Cacute cacute Ccaron ccaron dcroat
        """.split(separator: " ").map(String.init)
        return names
    }()

    static let cffStandardIndex: [String: Int] = {
        var map: [String: Int] = [:]
        for (i, n) in cffStandard.enumerated() where map[n] == nil { map[n] = i }
        return map
    }()

    static let macIndex: [String: Int] = {
        var map: [String: Int] = [:]
        for (i, n) in macStandard.enumerated() where map[n] == nil { map[n] = i }
        return map
    }()
}
