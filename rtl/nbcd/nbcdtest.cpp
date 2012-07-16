/*##############################################################################

    Copyright (C) 2011 HPCC Systems.

    All rights reserved. This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as
    published by the Free Software Foundation, either version 3 of the
    License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
############################################################################## */

#include "platform.h"
#define DECIMAL_OVERLOAD
#include "nbcd.hpp"
#include "bcd.hpp"
#include "jlog.hpp"

#define _elements_in(a) (sizeof(a)/sizeof((a)[0]))

const char * hex = "0123456789ABCDEF";

#ifdef _USE_CPPUNIT
#include <cppunit/extensions/HelperMacros.h>
#define ASSERT(a) { if (!(a)) CPPUNIT_ASSERT(a); }

// Usage: ASSERT(check(statement, "error: foo bar %d", variable));
//    or: success &= check(statement, "error: foo bar %d", variable);
bool check(bool condition, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
bool check(bool condition, const char *fmt, ...)
{
    if (!condition)
    {
        va_list args;
        va_start(args, fmt);
        VALOG(MCuserError, unknownJob, fmt, args);
        va_end(args);
    }
    return condition;
}

class NBcdTest : public CppUnit::TestFixture  
{
    CPPUNIT_TEST_SUITE(NBcdTest);
        CPPUNIT_TEST(testBcdUninitialized);
        CPPUNIT_TEST(testBcdCString);
        CPPUNIT_TEST(testBcdRoundTruncate);
        CPPUNIT_TEST(testBcdDecimal);
        CPPUNIT_TEST(testBcdInt);
        CPPUNIT_TEST(testBcdMultiply);
        CPPUNIT_TEST(testBcdDivideModulus);
        CPPUNIT_TEST(testBcdCompare);
        // Failing tests (due to precision)
        CPPUNIT_TEST(testBcdRandom);
        CPPUNIT_TEST(testBcdPower);
        CPPUNIT_TEST(testBcdPrecision);
    CPPUNIT_TEST_SUITE_END();
protected:

    static void expandHex(const void * bytes, unsigned size, char * target)
    {
        byte * src = (byte *)bytes;
        while (size--)
        {
            *target++ = hex[*src>>4];
            *target++ = hex[*src&15];
            src++;
        }
        *target=0;
    }

    void testMultiply(const char * left, const char * right, const char * expected)
    {
        if (!right) right = left;
        char temp[80];
        TempDecimal a = left;
        TempDecimal b = right;
        a.multiply(b);
        a.getCString(sizeof(temp), temp);
        ASSERT(check(strcmp(expected, temp) == 0, "ERROR: testMultiply/getCString: expected '%s', got '%s'", expected, temp));
        DecPushCString(left);
        DecPushCString(right);
        DecMul();
        DecPopCString(sizeof(temp),temp);
        ASSERT(check(strcmp(expected, temp) == 0, "ERROR: testMultiply/DecMul: expected '%s', got '%s'", expected, temp));
    }

    void testDivide(const char * left, const char * right, const char * expected)
    {
        char temp[80];
        TempDecimal a = left;
        TempDecimal b = right;
        a.divide(b);
        a.getCString(sizeof(temp), temp);
        ASSERT(check(strcmp(expected, temp) == 0, "ERROR: testDivide/getCString: expected '%s', got '%s'", expected, temp));
        DecPushCString(left);
        DecPushCString(right);
        DecDivide();
        DecPopCString(sizeof(temp),temp);
        ASSERT(check(strcmp(expected, temp) == 0, "ERROR: testDivide/DecDivide: expected '%s', got '%s'", expected, temp));
    }

    void testCompare(const char * left, const char * right, int expected)
    {
        TempDecimal a = left;
        TempDecimal b = right;
        int temp = a.compare(b);
        ASSERT(check(temp == expected, "ERROR: testCompare/positive: expected '%d', got '%d'", expected, temp));
        temp = b.compare(a);
        ASSERT(check(temp == -expected, "ERROR: testCompare/negative: expected '%d', got '%d'", expected, temp));

        DecPushCString(left);
        DecPushCString(right);
        temp = DecDistinct();
        ASSERT(check(expected == temp, "ERROR: testCompare/DecDistinct: expected '%d', got '%d'", expected, temp));
    }

    void testModulus(const char * left, const char * right, const char * expected)
    {
        char temp[80];
        TempDecimal a = left;
        TempDecimal b = right;
        a.modulus(b);
        a.getCString(sizeof(temp), temp);
        ASSERT(check(strcmp(expected, temp) == 0, "ERROR: testModulus: expected '%s', got '%s'", expected, temp));
    }

    void checkDecimal(const TempDecimal & value, const char * expected)
    {
        char temp[80];
        value.getCString(sizeof(temp), temp);
        ASSERT(check(strcmp(expected, temp) == 0, "ERROR: checkDecimal: expected '%s', got '%s'", expected, temp));
    }

    void checkDecimal(const TempDecimal & value, unsigned __int64 expected)
    {
        unsigned __int64 temp = value.getUInt64();
        ASSERT(check(expected == temp, "ERROR: checkDecimal/uint64: expected '%" I64F "d', got '%" I64F "d'", expected, temp));
    }

    void checkDecimal(const TempDecimal & value, __int64 expected)
    {
        __int64 temp = value.getInt64();
        ASSERT(check(expected == temp, "ERROR: checkDecimal/int64: expected '%" I64F "d', got '%" I64F "d'", expected, temp));
    }

    void checkBuffer(const void * buffer, const char * expected)
    {
        char temp[40];
        expandHex(buffer, strlen(expected)/2, temp);
        ASSERT(check(strcmp(expected, temp) == 0, "ERROR: checkBuffer: expected '%s', got '%s'", expected, temp));
    }

    // ========================================================= UNIT TESTS BELOW
    void testBcdRandom()
    {
        for (int i = 0; i < 1000; i++)
        {
            unsigned __int64 val1 = (rand() << 16) | rand();
            unsigned __int64 val2 = (rand() << 16) | rand();
            unsigned __int64 val3 = (rand() << 16) | rand();
            unsigned __int64 val4 = (rand() << 16) | rand();

            for (int i = 0; i < 2; i++)
            {
                TempDecimal d1 = val1;
                TempDecimal d2 = val2;
                TempDecimal d3 = val3;
                TempDecimal d4 = val4;

                d1.multiply(d2);
                d3.multiply(d4);
                checkDecimal(d1, val1*val2);
                checkDecimal(d3, val3*val4);
                d2.set(d1);
                d1.subtract(d3);
                d2.add(d3);
                checkDecimal(d1, (__int64)(val1*val2-val3*val4));
                checkDecimal(d2, (val1*val2+val3*val4));
            }
        }
    }
    
    void testBcdUninitialized()
    {
        // Test uninitialised
        TempDecimal zero, one=1, two(2);
        checkDecimal(zero, 0ULL);
        checkDecimal(one, 1ULL);
        checkDecimal(two, 2ULL);
        zero.add(one);
        checkDecimal(zero, 1ULL);
        zero.multiply(two);
        checkDecimal(zero, 2ULL);
    }

    void testBcdCString()
    {
        TempDecimal a,b,c;
        a.setString(10,"1234.56789");   // 1234.56789
        b.setString(8,"  123456.88");   // 123456
        c.setString(6," 0.123 ");

        char temp[80];
        a.getCString(sizeof(temp), temp);
        check(strcmp("1234.56789", temp) == 0, "ERROR: testBcdCString/a: expected '1234.56789', got '%s'", temp);
        b.getCString(sizeof(temp), temp);
        check(strcmp("123456", temp) == 0, "ERROR: testBcdCString/b: expected '123456', got '%s'", temp);
        c.getCString(sizeof(temp), temp);
        check(strcmp("0.123", temp) == 0, "ERROR: testBcdCString/c: expected '0.123', got '%s'", temp);

        a.add(b);
        a.getCString(sizeof(temp), temp);
        check(strcmp("124690.56789", temp) == 0, "ERROR: testBcdCString/a+b: expected '124690.56789', got '%s'", temp);
        b.subtract(a);
        b.getCString(sizeof(temp), temp);
        check(strcmp("-1234.56789", temp) == 0, "ERROR: testBcdCString/-a: expected '-1234.56789', got '%s'", temp);
    }

    void testBcdRoundTruncate()
    {
        char temp[80];
        TempDecimal c = "9.53456";
        checkDecimal(c, "9.53456");
        c.round(4);
        checkDecimal(c,"9.5346");
        c.round(8);
        checkDecimal(c, "9.5346");
        c.round(2);
        checkDecimal(c, "9.53");
        c.round();
        checkDecimal(c, "10");

        c = 1234567.8901;
        checkDecimal(c, "1234567.8901");
        c.round(-3);
        checkDecimal(c, "1235000");

        c = 1234567.8901234567;
        c.getCString(sizeof(temp), temp);
        ASSERT(check(c.getReal() == 1234567.890123457, "ERROR: testBcdRoundTruncate/real: expected '1234567.890123457', got '%.8f'", c.getReal()));
        ASSERT(check(strcmp("1234567.890123457", temp) == 0, "ERROR: testBcdRoundTruncate/cstr: expected '1234567.890123457', got '%s'", temp));

        c = "9.53456";
        c.truncate(4);
        checkDecimal(c, "9.5345");
        c.truncate(8);
        checkDecimal(c, "9.5345");
        c.truncate(2);
        checkDecimal(c, "9.53");
        c.truncate();
        checkDecimal(c, "9");

        TempDecimal x1 = 1;
        x1.round(-3);
        checkDecimal(x1, (__int64)0);
        TempDecimal x2 = 100;
        x2.round(-3);
        checkDecimal(x2, (__int64)0);
        TempDecimal x3 = 499;
        x3.round(-3);
        checkDecimal(x3, (__int64)0);
        TempDecimal x4 = 500;
        x4.round(-3);
        checkDecimal(x4, (__int64)1000);
        TempDecimal x5 = 1000;
        x5.round(-3);
        checkDecimal(x5, (__int64)1000);
        TempDecimal x6 = 1499;
        x6.round(-3);
        checkDecimal(x6, (__int64)1000);
        TempDecimal x7 = 1500;
        x7.round(-3);
        checkDecimal(x7, (__int64)2000);
        TempDecimal x8 = 10000;
        x8.round(-3);
        checkDecimal(x8, (__int64)10000);
        TempDecimal x9 = 10499;
        x9.round(-3);
        checkDecimal(x9, (__int64)10000);
        TempDecimal x10 = 10500;
        x10.round(-3);
        checkDecimal(x10, (__int64)11000);
        TempDecimal x11 = -10500;
        x11.round(-3);
        checkDecimal(x11, (__int64)-11000);
    }

    void testBcdDecimal()
    {
        TempDecimal a = "123.2345";
        unsigned decBufferSize=5;
        char decBuffer[7];
        char * decBufferPtr = decBuffer+1;
        decBuffer[0]=(char)0xCC;
        decBuffer[6]=(char)0xCC;

        a.getUDecimal(decBufferSize, 4, decBufferPtr);
        checkBuffer(decBuffer, "CC0001232345CC");
        a.getUDecimal(decBufferSize, 3, decBufferPtr);
        checkBuffer(decBuffer, "CC0000123234CC");
        a.getUDecimal(decBufferSize, 2, decBufferPtr);
        checkBuffer(decBuffer, "CC0000012323CC");
        a.getUDecimal(decBufferSize, 6, decBufferPtr);
        checkBuffer(decBuffer, "CC0123234500CC");
        a.getUDecimal(decBufferSize, 7, decBufferPtr);
        checkBuffer(decBuffer, "CC1232345000CC");
        a.getUDecimal(decBufferSize, 8, decBufferPtr);
        checkBuffer(decBuffer, "CC2323450000CC");

        a = "0.0001";
        a.getUDecimal(decBufferSize, 4, decBufferPtr);
        checkBuffer(decBuffer, "CC0000000001CC");
        a.getUDecimal(decBufferSize, 3, decBufferPtr);
        checkBuffer(decBuffer, "CC0000000000CC");

        a = "123.2345";
        a.getDecimal(decBufferSize, 4, decBufferPtr);
        checkBuffer(decBuffer, "CC001232345FCC");
        a.getDecimal(decBufferSize, 3, decBufferPtr);
        checkBuffer(decBuffer, "CC000123234FCC");
        a.getDecimal(decBufferSize, 2, decBufferPtr);
        checkBuffer(decBuffer, "CC000012323FCC");
        a.getDecimal(decBufferSize, 5, decBufferPtr);
        checkBuffer(decBuffer, "CC012323450FCC");
        a.getDecimal(decBufferSize, 6, decBufferPtr);
        checkBuffer(decBuffer, "CC123234500FCC");
        a.getDecimal(decBufferSize, 7, decBufferPtr);
        checkBuffer(decBuffer, "CC232345000FCC");
        a.getDecimal(decBufferSize, 5, decBufferPtr, 0xEB);
        checkBuffer(decBuffer, "CC012323450ECC");

        a = "0.0001";
        a.getDecimal(decBufferSize, 4, decBufferPtr);
        checkBuffer(decBuffer, "CC000000001FCC");
        a.getDecimal(decBufferSize, 3, decBufferPtr);
        checkBuffer(decBuffer, "CC000000000FCC");

        a = "-123.2345";
        a.getDecimal(decBufferSize, 4, decBufferPtr);
        checkBuffer(decBuffer, "CC001232345DCC");
        a.getDecimal(decBufferSize, 3, decBufferPtr, 0xFB);
        checkBuffer(decBuffer, "CC000123234BCC");

        memcpy(decBufferPtr, "\x00\x12\x34\x56\x78", 5);
        a.setUDecimal(5, 4, decBufferPtr);
        checkDecimal(a, "1234.5678");
        a.setUDecimal(5, 3, decBufferPtr);
        checkDecimal(a,"12345.678");
        a.setUDecimal(5, 0, decBufferPtr);
        checkDecimal(a, "12345678");
        a.setUDecimal(5, 9, decBufferPtr);
        checkDecimal(a, "0.012345678");

        memcpy(decBufferPtr, "\x00\x12\x34\x56\x7D", 5);
        a.setDecimal(5, 4, decBufferPtr);
        checkDecimal(a, "-123.4567");
        a.setDecimal(5, 3, decBufferPtr);
        checkDecimal(a, "-1234.567");
        a.setDecimal(5, 0, decBufferPtr);
        checkDecimal(a, "-1234567");
        a.setDecimal(5, 8, decBufferPtr);
        checkDecimal(a,"-0.01234567");

        memcpy(decBufferPtr, "\x00\x12\x34\x56\x7F", 5);
        a.setDecimal(5, 4, decBufferPtr);
        checkDecimal(a, "123.4567");
        a.setDecimal(5, 3, decBufferPtr);
        checkDecimal(a, "1234.567");
        a.setDecimal(5, 0, decBufferPtr);
        checkDecimal(a, "1234567");
        a.setDecimal(5, 8, decBufferPtr);
        checkDecimal(a, "0.01234567");
    }

    void testBcdInt()
    {
        TempDecimal a, b;
        for (unsigned i1 = 0; i1 <= 1000; i1++)
        {
            a = i1;
            ASSERT(check(a.getUInt() == i1, "ERROR: testBcdInt/getUInt: expected '%d', got '%d'", i1, a.getUInt()));
        }
        for (unsigned i3 = 0; i3 <= 100; i3++)
        {
            a = i3;
            b = 10;
            a.multiply(b);
            ASSERT(check(a.getUInt() == i3*10, "ERROR: testBcdInt/getUInt*3: expected '%d', got '%d'", i3*10, a.getUInt()));
        }

        for (unsigned i2 = 0; i2 <= 100; i2++)
        {
            TempDecimal x = i2;
            TempDecimal y = 100;
            y.multiply(x);
            ASSERT(check(100*i2 == (unsigned)y.getInt(), "ERROR: testBcdInt/getInt*100: expected '%d', got '%d'", 100*i2, y.getInt()));
            x.multiply(x);
            ASSERT(check(i2*i2 == (unsigned)x.getInt(), "ERROR: testBcdInt/getInt*getInt: expected '%d', got '%d'", i2*i2, x.getInt()));
        }
    }

    void testBcdMultiply()
    {
        testMultiply("-1","0","0");
        testMultiply("-1","2","-2");
        testMultiply("-1","-2","2");
        testMultiply("1","-2","-2");
        testMultiply("9","9","81");
        testMultiply("99","99","9801");
        testMultiply("999","999","998001");
        testMultiply("9999","9999","99980001");
        testMultiply("99.999999999",NULL,"9999.999999800000000001");
        testMultiply("9999.999999999",NULL,"99999999.999980000000000001");
        testMultiply("0.0000000000000001",NULL,"0.00000000000000000000000000000001");
        testMultiply("0.0000000000000009",NULL,"0.00000000000000000000000000000081");
        testMultiply("0.00000000000000001",NULL,"0");
        testMultiply("0.00000000000000009","0.0000000000000009","0.00000000000000000000000000000008");
        testMultiply("9999999999999999","10000000000000001","99999999999999999999999999999999");
        testMultiply("101","99009901","10000000001");
        testMultiply("0.000000000000000101","0.0000000000000000099009901","0");
        testMultiply("0.000000000000000101","0.000000000000000099009901","0.00000000000000000000000000000001");
        testMultiply("109", "9174311926605504587155963302.75229357798165137614678899082568", "999999999999999999999999999999.99999999999999999999999999999912");

        TempDecimal a = "9999999999999999";
        TempDecimal b = "10000000000000002";
        char temp[80];
        a.multiply(b);
        a.getCString(sizeof(temp), temp);
        ASSERT(check(strcmp("9999999999999998", temp) == 0, "ERROR: testBcdMultiply/overflow: expected '9999999999999998', got '%s'", temp));
    }

    void testBcdDivideModulus()
    {
        //Divide
        testDivide("1","1","1");
        testDivide("125","5","25");
        testDivide("99980001","9999","9999");
        testDivide("0.1234","10000000000000000000000000000000","0.00000000000000000000000000000001");
        testDivide("0.1234","20000000000000000000000000000000","0");
        testDivide("1","0.00000000000000000000000000000002", "50000000000000000000000000000000");
        testDivide("1","3", "0.33333333333333333333333333333333");
        testDivide("1000000000000000000000000000000","109", "9174311926605504587155963302.75229357798165137614678899082568");
        testModulus("1000000000000000000000000000000","109", "82");
        testModulus("10","5","0");
        testModulus("10","6","4");
        testModulus("10","-6","4");
        testModulus("-10","6","-4");
        testModulus("-10","-6","-4");
    }

    void testBcdCompare()
    {
        testCompare("1","1.0000",0);
        testCompare("-1","1.0000",-1);
        testCompare("1","-1.0000",+1);
        testCompare("-1","-1.0000",0);
        testCompare("1","2.0000",-1);
        testCompare("-1","2.0000",-1);
        testCompare("1","-2.0000",+1);
        testCompare("-1","-2.0000",+1);
        testCompare("100","2.0000",+1);
        testCompare("-100","2.0000",-1);
        testCompare("100","-2.0000",+1);
        testCompare("-100","-2.0000",-1);
        testCompare("0","1",-1);
        testCompare("0","-1",+1);
        testCompare("0","0",0);

        testCompare("1234","1230",+1);
        testCompare("1234.0001","1230.99",+1);
        testCompare("1234.999","1234.99",+1);
        testCompare("1234.989","1234.99",-1);
        testCompare("-1234","-1230",-1);
        testCompare("-1234.0001","-1230.99",-1);
        testCompare("-1234.999","-1234.99",-1);
        testCompare("-1234.989","-1234.99",+1);

    }

    void testBcdPower()
    {
        //MORE: Test power functions...
        const char * values[] = { "0.00001", "10000", "-1", "-10", "1.0001", "9.99" };
        TempDecimal one(1);
        for (unsigned idx = 0; idx < _elements_in(values); idx++)
        {
            TempDecimal value = values[idx];
            TempDecimal sofar1 = 1;
            TempDecimal sofar2 = 1;

            bool success=true;
            for (int power = 0; power < 10; power++)
            {
                TempDecimal powerValue1 = values[idx];
                TempDecimal powerValue2 = values[idx];
                powerValue1.power(power);
                powerValue2.power(-power);

                char temp1[80], temp2[80], temp3[80];
                if (sofar1.compare(powerValue1) != 0)
                {
                    TempDecimal diff = powerValue1;
                    diff.subtract(sofar1);
                    sofar1.getCString(sizeof(temp1), temp1);
                    powerValue1.getCString(sizeof(temp2), temp2);
                    diff.getCString(sizeof(temp3), temp3);
                    success &= check(false, "ERROR: %s^%d=%s (expected %s) diff %s", values[idx], power, temp2, temp1, temp3);
                }
                if (sofar2.compare(powerValue2) != 0)
                {
                    TempDecimal diff = powerValue2;
                    diff.subtract(sofar2);
                    sofar2.getCString(sizeof(temp1), temp1);
                    powerValue2.getCString(sizeof(temp2), temp2);
                    diff.getCString(sizeof(temp3), temp3);
                    success &= check(false, "ERROR: %s^%d=%s (expected %s) diff %s", values[idx], -power, temp2, temp1, temp3);
                }

                //internal consistency test, but liable to rounding errors....
                if (true)
                {
                    powerValue1.multiply(powerValue2);
                    if (power && (powerValue1.compareNull() != 0) && (powerValue1.compare(one) != 0))
                    {
                        TempDecimal diff = powerValue1;
                        diff.subtract(one);
                        one.getCString(sizeof(temp1), temp1);
                        powerValue1.getCString(sizeof(temp2), temp2);
                        diff.getCString(sizeof(temp3), temp3);
                        success &= check(false, "ERROR: %s^%d^-%d=%s (expected %s) diff %s", values[idx], power, power, temp2, temp1, temp3);
                    }
                }

                sofar1.multiply(value);
                sofar2.divide(value);
            }
            ASSERT(check(success, "ERROR: testBcdPower: one or more errors detected above."));
        }
    }

    void testBcdPrecision()
    {
        //check rounding is done correctly to number of significant digits
        checkDecimal(9999999.12, "9999999.12");
        checkDecimal(-9999999.12, "-9999999.12");
        checkDecimal(9999999.12345678, "9999999.12345678");
        checkDecimal(-9999999.12345678, "-9999999.12345678");
        checkDecimal(9999999.123456789, "9999999.12345679");
        checkDecimal(-9999999.123456789, "-9999999.12345679");

        checkDecimal(99999991234567800.00, "99999991234567800");
        checkDecimal(-99999991234567800.00, "-99999991234567800");
        checkDecimal(99999991234567890.00, "99999991234567900");
        checkDecimal(-99999991234567890.00, "-99999991234567900");

        // in vc++ these real constants seem to only have 14 significant digits
//      checkDecimal(0.99999991234567800, "0.999999912345678");
//      checkDecimal(0.99999991234567890, "0.999999912345679");
//      checkDecimal(0.099999991234567800, "0.0999999912345678");
//      checkDecimal(0.099999991234567890, "0.0999999912345679");
    }
};

CPPUNIT_TEST_SUITE_REGISTRATION( NBcdTest );
CPPUNIT_TEST_SUITE_NAMED_REGISTRATION( NBcdTest, "NBcdTest" );

#endif
