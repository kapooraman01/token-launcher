import { BadRequestException, Injectable, PipeTransform } from '@nestjs/common';
import { getAddress, isAddress } from 'ethers';

/** Validates an address route parameter and normalises it to its checksummed form. */
@Injectable()
export class ParseAddressPipe implements PipeTransform<string, string> {
  transform(value: string): string {
    if (!isAddress(value)) {
      throw new BadRequestException('Invalid address');
    }
    return getAddress(value);
  }
}
